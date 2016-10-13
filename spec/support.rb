# frozen_string_literal: true
require 'simplecov'

require 'chirp_tracker'
require 'rack/test'

RSpec.configure do |conf|
  conf.include Rack::Test::Methods
end
