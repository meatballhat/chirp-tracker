$LOAD_PATH.unshift(File.expand_path('../lib', __FILE__))

require 'json'
require 'openssl'
require 'redis'
require 'sinatra/base'

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
    def respond_json(whatever)
      JSON.pretty_generate(whatever) << "\n"
    end

    def verify_hub_signature!(request)
      hub_sig = request.env.fetch('HTTP_X_HUB_SIGNATURE')
      request.body.rewind
      payload_body = request.body.read
      signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), settings.secret_token, payload_body)
      return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, hub_sig)
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

    body = JSON.parse(params[:payload])
    head_commit = body.fetch('head_commit').fetch('id')
    settings.db.setex("github:payload:#{head_commit}", settings.ttl, params[:payload])
    settings.db.setex("github:timestamp:#{head_commit}", settings.ttl, Time.now.utc.to_i)

    status 200
    respond_json ok: :great
  end

  post '/travis' do
    log message: 'received something from travis', level: :debug, params: params

    unless settings.development? || settings.travis_auth_disabled?
      halt 401 unless settings.auths.include?(request.env['HTTP_AUTHORIZATION'])
    end

    halt 400 unless params[:payload]

    body = JSON.parse(params[:payload])
    head_commit = body.fetch('commit')
    settings.db.setex("travis:payload:#{head_commit}", settings.ttl, params[:payload])
    settings.db.setex("travis:timestamp:#{head_commit}", settings.ttl, Time.now.utc.to_i)

    status 200
    respond_json ok: :great
  end

  get '/chirps' do
    chirps = settings.db.keys('github:timestamp:*').map do |key|
      commit = key.split(':').last
      github_timestamp = settings.db.get(key) || 0.0
      travis_timestamp = settings.db.get("travis:timestamp:#{commit}") || 0.0
      {
        commit: commit,
        delta: Float(travis_timestamp) - Float(github_timestamp)
      }
    end

    status 200
    respond_json chirps: chirps
  end

  def run!
    log message: 'starting up'
    super
  end

  run! if __FILE__ == $0
end
