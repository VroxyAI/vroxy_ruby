# frozen_string_literal: true

require "json"
require "vroxy/safe_query/errors"
require "vroxy/safe_query/signature"
require "vroxy/safe_query/nonce_store"

module Vroxy
  module Tools
    class Endpoint
      HEADERS = {
        "content-type"  => "application/json",
        "cache-control" => "no-store"
      }.freeze

      TIMESTAMP_HEADER = "HTTP_X_VROXY_TIMESTAMP"
      NONCE_HEADER     = "HTTP_X_VROXY_NONCE"
      SIGNATURE_HEADER = "HTTP_X_VROXY_SIGNATURE"
      PATH_RE          = %r{\A/vroxy/tools(?:/([a-z][a-z0-9_]{1,39}))?\z}

      def self.call(env)
        new.call(env)
      end

      def call(env)
        config = Vroxy.configuration.safe_query
        return json(404, "not found") unless config.secret.to_s.strip != ""
        return json(404, "not found") if Vroxy.configuration.tools.host_tools.empty?
        return json(405, "method not allowed") unless env["REQUEST_METHOD"].to_s.casecmp("POST").zero?

        name = tool_name_from(env)
        return json(404, "not found") if name.nil?

        tool = Vroxy.configuration.tools[name]
        return json(404, "unknown tool") unless tool&.resolved_kind == "host"

        body = read_body(env, SafeQuery::Config::MAX_BODY_BYTES)
        return json(413, "request body too large") if body.nil?

        denial = authenticate(config, env, body)
        return json(401, denial) if denial

        unless config.rate_limiter.allow?(config.max_requests_per_minute)
          return json(429, "rate limit exceeded")
        end

        payload = parse_json(body)
        return json(400, "body must be a JSON object") unless payload.is_a?(Hash)

        arguments = payload["arguments"]
        arguments = {} if arguments.nil?
        return json(400, "`arguments` must be an object") unless arguments.is_a?(Hash)

        result = tool.call(arguments)
        respond(200, { "ok" => true, "result" => normalize(result) })
      rescue StandardError => e
        warn "[vroxy] tools endpoint error: #{e.class}: #{e.message}"
        json(500, "internal error")
      end

      private

      def tool_name_from(env)
        path = env["PATH_INFO"].to_s
        full = "#{env['SCRIPT_NAME']}#{path}"
        match = PATH_RE.match(path) || PATH_RE.match(full)
        match && match[1]
      end

      def authenticate(config, env, body)
        timestamp = env[TIMESTAMP_HEADER].to_s
        nonce     = env[NONCE_HEADER].to_s
        signature = env[SIGNATURE_HEADER].to_s

        return "missing signature headers" if timestamp.empty? || nonce.empty? || signature.empty?

        unless SafeQuery::Signature.fresh_timestamp?(timestamp, tolerance: config.timestamp_tolerance)
          return "timestamp outside the accepted window"
        end

        verified = SafeQuery::Signature.verify(
          secret: config.secret, timestamp: timestamp, nonce: nonce,
          body: body, signature: signature
        )
        return "signature mismatch" unless verified

        fresh = SafeQuery::Nonce.fresh?(config.nonce_store, nonce, ttl: config.timestamp_tolerance)
        return "nonce already used" unless fresh

        nil
      end

      def read_body(env, limit)
        input = env["rack.input"]
        return +"" if input.nil?

        data = input.read(limit + 1).to_s
        input.rewind if input.respond_to?(:rewind)
        return nil if data.bytesize > limit

        data
      end

      def parse_json(body)
        JSON.parse(body)
      rescue JSON::ParserError, TypeError
        nil
      end

      def normalize(result)
        case result
        when Hash
          result.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
        when Array, String, Numeric, TrueClass, FalseClass, NilClass
          result
        else
          result.respond_to?(:as_json) ? result.as_json : result.to_s
        end
      end

      def json(status, message)
        respond(status, { "ok" => false, "error" => message })
      end

      def respond(status, payload)
        [ status, HEADERS.dup, [ JSON.generate(payload) ] ]
      end
    end
  end
end
