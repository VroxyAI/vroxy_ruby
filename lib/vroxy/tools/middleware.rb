# frozen_string_literal: true

require "vroxy/tools/endpoint"

module Vroxy
  module Tools
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless tools_path?(env)

        Endpoint.call(env)
      end

      private

      def tools_path?(env)
        path = env["PATH_INFO"].to_s
        full = "#{env['SCRIPT_NAME']}#{path}"
        Endpoint::PATH_RE.match?(path) || Endpoint::PATH_RE.match?(full)
      end
    end
  end
end
