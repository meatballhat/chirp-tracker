# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path('../lib', __FILE__))

require 'fileutils'
require 'json'
require 'openssl'
require 'redis'
require 'sinatra/base'
require 'sinatra/json'
require 'sinatra/streaming'
require 'time'

require_relative 'l2met_log'
require_relative 'sinatra/l2met'

L2metLog.default_log_level = ENV['DEBUG'] ? :debug : :info

class ChirpTracker < Sinatra::Base
  include L2metLog
  helpers Sinatra::Streaming

  set :db, Redis.new(
    url: (ENV[
      ENV['REDIS_PROVIDER'] || 'REDIS_URL'
    ] || 'redis://localhost:6379/0')
  )
  set :ttl, Integer(ENV.fetch('PAYLOAD_TTL', '3600'))
  set :secret_token, ENV['SECRET_TOKEN'].to_s
  set :auths, ENV['TRAVIS_AUTHS'].to_s.split(':').map { |a| "token #{a.strip}" }
  set :max_kb, Integer(ENV.fetch('MAX_KB', 1_000_000))

  set :travis_auth_disabled, !ENV['TRAVIS_AUTH_DISABLED'].nil?

  helpers do
    def verify_hub_signature!(request)
      hub_sig = request.env.fetch('HTTP_X_HUB_SIGNATURE')
      request.body.rewind
      payload_body = request.body.read
      signature = 'sha1=' + OpenSSL::HMAC.hexdigest(
        OpenSSL::Digest.new('sha1'), settings.secret_token, payload_body
      )
      return halt 500, "Signatures didn't match!" unless
        Rack::Utils.secure_compare(signature, hub_sig)
    end

    def simple_sanitized(str)
      str.gsub(%r{[^-a-zA-Z0-9_\/\.\*].*}, '')
    end
  end

  configure do
    extend L2metLog
    $stdout.sync = true
  end

  before do
    content_type 'application/json'
  end

  post '/github' do
    unless settings.development?
      halt 400, 'No github signature' unless
        request.env.key?('HTTP_X_HUB_SIGNATURE')
      verify_hub_signature!(request)
    end

    log message: 'received something from github', level: :debug, params: params

    halt 400, 'missing payload' unless params[:payload]

    body = JSON.parse(params[:payload])

    halt 400, 'missing expected payload keys' unless
      body.key?('head_commit') && body.key?('repository')

    log body.merge(message: 'parsed body', level: :debug)

    head_commit = body.fetch('head_commit').fetch('id')
    repo = body.fetch('repository').fetch('full_name')

    settings.db.setex(
      "github:payloads:#{repo}:#{head_commit}",
      settings.ttl,
      params[:payload]
    )

    settings.db.setex(
      "github:timestamps:#{repo}:#{head_commit}",
      settings.ttl,
      Time.now.utc.to_i
    )

    status 200
    json ok: :great
  end

  post '/travis' do
    log message: 'received something from travis', level: :debug, params: params

    unless settings.development? || settings.travis_auth_disabled?
      halt 401 unless settings.auths.include?(request.env['HTTP_AUTHORIZATION'])
    end

    halt 400, 'missing payload' unless params[:payload]

    body = JSON.parse(params[:payload])
    halt 400, 'missing expected payload keys' unless
      body.key?('commit') && body.key?('repository')

    head_commit = body.fetch('commit')

    log body.merge(message: 'parsed body', level: :debug)

    queues_timestamps = {}
    body.fetch('matrix', []).each do |entry|
      queue = Hash[
        Array(entry.fetch(
          'config', {}
        ).fetch(
          'env', ''
        )).first.split.map { |s| s.split('=') }
      ].fetch(
        'QUEUE', 'unknown'
      ).gsub(/['"]$/, '').gsub(/^['"]/, '')
      next if queue == 'unknown'
      queues_timestamps[queue] = Time.parse(entry.fetch('finished_at'))
    end

    repo = %W(
      #{body.fetch('repository').fetch('owner_name')}
      #{body.fetch('repository').fetch('name')}
    ).join('/')

    queues_timestamps.each do |queue, timestamp|
      settings.db.setex(
        "travis:payloads:#{repo}:#{queue}:#{head_commit}",
        settings.ttl,
        params[:payload]
      )
      settings.db.setex(
        "travis:timestamps:#{repo}:#{queue}:#{head_commit}",
        settings.ttl,
        timestamp.to_i
      )
    end

    status 200
    json ok: :great
  end

  post '/stats' do
    queue = request.env['HTTP_TRAVIS_QUEUE'] || 'unknown'
    site = request.env['HTTP_TRAVIS_SITE'] || 'unknown'
    stats = {}
    begin
      stats.merge!(JSON.parse(request.body.read))
    rescue => e
      halt 400, JSON.dump(error: e.to_s)
    end

    halt 400, JSON.dump(error: 'missing data key') unless stats.key?('data')

    data = stats.fetch('data')

    unless data.all? { |r| r.key?('script') && r.key?('exe_time') }
      halt 400, JSON.dump(error: 'incorrect record format')
    end

    log_record = {}

    data.each do |record|
      key = "sample#chirp.#{site}.#{queue}.#{record.fetch('script')}"
      log_record[key] = record.fetch('exe_time')
    end

    halt 200, JSON.dump(huh: :what) if log_record.empty?

    log(log_record)
    status 200
    json ok: :great
  end

  get '/chirps' do
    now = Time.now.utc.to_i
    param_limit = Integer(simple_sanitized(params[:limit] || '100'))
    param_limit = param_limit < 1 ? 1 : param_limit
    param_repo = simple_sanitized(params[:repo] || '*')
    param_queue = simple_sanitized(params[:queue] || '*')

    chirps = settings.db.keys(
      "travis:timestamps:#{param_repo}:#{param_queue}:*"
    ).map do |key|
      repo, queue, commit = key.split(':')[2..4]

      travis_timestamp = Float(
        settings.db.get(key) || 0.0
      )

      github_timestamp = Float(
        settings.db.get("github:timestamps:#{repo}:#{commit}") || 0.0
      )

      {
        age: now - travis_timestamp,
        queue: queue,
        commit: commit,
        delta: travis_timestamp - github_timestamp,
        github_timestamp: github_timestamp,
        repo: repo,
        travis_timestamp: travis_timestamp
      }
    end

    log_params = {
      queue: param_queue,
      limit: param_limit,
      repo: param_repo
    }

    log log_params.merge(
      message: 'pre-filtered chirps',
      count: chirps.length,
      level: :info
    )

    unless params[:nofilter] == '1'
      chirps.reject! do |chirp|
        chirp[:delta].negative? ||
          chirp[:github_timestamp].zero? ||
          chirp[:travis_timestamp].zero?
      end
    end

    log log_params.merge(
      message: 'post-filtered chirps',
      count: chirps.length,
      level: :info
    )

    chirps.sort_by! { |chirp| chirp[:travis_timestamp] }
    chirps.reverse!

    status 200
    json(
      data: chirps[0..(param_limit - 1)],
      meta: {
        params: {
          queue: param_queue,
          count: chirps.length,
          limit: param_limit,
          repo: param_repo
        },
        most_recent: chirps.first
      }
    )
  end

  get '/kb/:kb' do
    kilobytes = Float(params[:kb] || '1000')
    halt 400, '{"error":"too much kb"}' if kilobytes > settings.max_kb

    status 200
    content_type 'application/octet-stream'

    stream do |out|
      loop do
        break if out.closed? || (out.pos / 1000.0) >= kilobytes
        out.print('z' * 1000)
        out.flush
      end
    end
  end

  post '/kb/:kb' do
    halt 400, '{"error":"missing bytes param"}' unless params[:bytes]

    kilobytes = Integer(params[:kb])

    tmp_path = params[:bytes][:tempfile].path
    size = File.stat(tmp_path).size
    size_kb = size / 1000.0

    log message: 'received file upload', path: tmp_path, size_kb: size_kb

    halt 400, %(
      {"error":"mismatched size: expected=#{kilobytes} actual=#{size_kb}"}
    ).strip unless size_kb == kilobytes

    FileUtils.rm_f(tmp_path)
    status 200
    json ok: :wow
  end

  def run!
    log message: 'starting up'
    super
  end

  run! if __FILE__ == $PROGRAM_NAME
end
