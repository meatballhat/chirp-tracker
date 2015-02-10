$LOAD_PATH.unshift(File.expand_path('../lib', __FILE__))

require 'json'
require 'redis'
require 'sinatra/base'

require_relative 'l2met_log'
require_relative 'sinatra/l2met'

L2metLog.default_log_level = ENV['DEBUG'] ? :debug : :info

class ChirpTracker < Sinatra::Base
  include L2metLog

  set :db do
    Redis.new(url: ENV[ENV['REDIS_PROVIDER'] || 'REDIS_URL'] || 'redis://localhost:6379/0')
  end

  set :secret_token, "#{ENV['SECRET_TOKEN']}"

  helpers do
    def respond_json(whatever)
      JSON.pretty_generate(whatever) << "\n"
    end

    def verify_hub_signature!(request)
      request.body.rewind
      payload_body = request.body.read
      signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), settings.secret_token, payload_body)
      return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
    end
  end

  configure do
    extend L2metLog
    $stdout.sync = true

    log message: 'starting up'
  end

  post '/github' do
    verify_hub_signature!(request)

    log message: 'received something from github', level: :debug, params: params
    body = JSON.parse(params[:payload])
    status 200
    respond_json ok: :great
  end

  post '/travis' do
    log message: 'received something from travis', level: :debug, params: params
    halt 401 unless settings.auths.include?(request.env['HTTP_AUTHORIZATION'])
    status 200
    respond_json ok: :great
  end

  run! if __FILE__ == $0
end
