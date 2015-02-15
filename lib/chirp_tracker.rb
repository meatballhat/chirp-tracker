$LOAD_PATH.unshift(File.expand_path('../lib', __FILE__))

require 'json'
require 'openssl'
require 'redis'
require 'sinatra/base'
require 'sinatra/json'

require_relative 'l2met_log'
require_relative 'sinatra/l2met'

L2metLog.default_log_level = ENV['DEBUG'] ? :debug : :info

class ChirpTracker < Sinatra::Base
  include L2metLog

  set :db, Redis.new(url: ENV[ENV['REDIS_PROVIDER'] || 'REDIS_URL'] || 'redis://localhost:6379/0')
  set :ttl, Integer(ENV.fetch('PAYLOAD_TTL', '3600'))
  set :secret_token, "#{ENV['SECRET_TOKEN']}"
  set :auths, "#{ENV['TRAVIS_AUTHS']}".split(':').map { |auth| "token #{auth.strip}" }
  set :travis_auth_disabled, !!ENV['TRAVIS_AUTH_DISABLED']

  helpers do
    def verify_hub_signature!(request)
      hub_sig = request.env.fetch('HTTP_X_HUB_SIGNATURE')
      request.body.rewind
      payload_body = request.body.read
      signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), settings.secret_token, payload_body)
      return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, hub_sig)
    end

    def dumb_sanitized(str)
      str.gsub(/[^-a-zA-Z0-9_\/\.\*].*/, '')
    end
  end

  configure do
    extend L2metLog
    $stdout.sync = true
  end

  post '/github' do
    unless settings.development?
      halt 400, 'No github signature' unless request.env.key?('HTTP_X_HUB_SIGNATURE')
      verify_hub_signature!(request)
    end

    log message: 'received something from github', level: :debug, params: params

    halt 400, 'missing payload' unless params[:payload]

    body = JSON.parse(params[:payload])

    halt 400, 'missing expected payload keys' unless body.key?('head_commit') && body.key?('repository')

    head_commit = body.fetch('head_commit').fetch('id')
    repo = body.fetch('repository').fetch('full_name')

    settings.db.setex("github:payloads:#{repo}:#{head_commit}", settings.ttl, params[:payload])
    settings.db.setex("github:timestamps:#{repo}:#{head_commit}", settings.ttl, Time.now.utc.to_i)

    status 200
    json ok: :great
  end

  post '/travis' do
    log message: 'received something from travis', level: :debug, params: params

    unless settings.development? || settings.travis_auth_disabled?
      halt 401 unless settings.auths.include?(request.env['HTTP_AUTHORIZATION'])
    end

    halt 400, 'missing payload'  unless params[:payload]

    body = JSON.parse(params[:payload])
    halt 400, 'missing expected payload keys' unless body.key?('commit') && body.key?('repository')

    head_commit = body.fetch('commit')
    branch = body.fetch('branch')
    repo = "#{body.fetch('repository').fetch('owner_name')}/#{body.fetch('repository').fetch('name')}"
    settings.db.setex("travis:payloads:#{repo}:#{branch}:#{head_commit}", settings.ttl, params[:payload])
    settings.db.setex("travis:timestamps:#{repo}:#{branch}:#{head_commit}", settings.ttl, Time.now.utc.to_i)

    status 200
    json ok: :great
  end

  get '/chirps' do
    now = Time.now.utc.to_i
    param_limit = Integer(dumb_sanitized(params[:limit] || '100'))
    param_limit = param_limit < 1 ? 1 : param_limit
    param_repo = dumb_sanitized(params[:repo] || '*')
    param_branch = dumb_sanitized(params[:branch] || '*')

    chirps = settings.db.keys("travis:timestamps:#{param_repo}:#{param_branch}:*").map do |key|
      repo, branch, commit = key.split(':')[2..4]
      travis_timestamp = Float(settings.db.get(key) || 0.0)
      github_timestamp = Float(settings.db.get("github:timestamps:#{repo}:#{commit}") || 0.0)
      {
        age: now - travis_timestamp,
        branch: branch,
        commit: commit,
        delta: travis_timestamp - github_timestamp,
        github_timestamp: github_timestamp,
        repo: repo,
        travis_timestamp: travis_timestamp
      }
    end

    chirps.reject! { |chirp| chirp[:delta] < 0 }
    chirps.sort_by! { |chirp| chirp[:travis_timestamp] }
    chirps.reverse!

    status 200
    json chirps: chirps[0..(param_limit-1)], _meta: {
      params: {
        branch: param_branch,
        count: chirps.length,
        limit: param_limit,
        repo: param_repo
      },
      most_recent: chirps.first,
    }
  end

  def run!
    log message: 'starting up'
    super
  end

  run! if __FILE__ == $0
end
