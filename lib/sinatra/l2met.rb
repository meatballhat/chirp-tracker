require_relative '../l2met_log'

module Sinatra
  module L2met
    module Helpers
      include L2metLog

      def self.registered(app)
        app.helpers L2met::Helpers
      end
    end
  end

  register L2met
end
