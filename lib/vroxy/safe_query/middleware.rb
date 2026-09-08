# frozen_string_literal: true

require "vroxy/safe_query/endpoint"

module Vroxy
  module SafeQuery
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        config = Vroxy.configuration.safe_query
        return @app.call(env) unless config.enabled?
        return @app.call(env) unless matches?(config, env)

        Endpoint.call(env)
      end

      private

      def matches?(config, env)
        path_info = env["PATH_INFO"].to_s
        full      = "#{env['SCRIPT_NAME']}#{path_info}"
        config.path == path_info || config.path == full
      end
    end
  end
end
