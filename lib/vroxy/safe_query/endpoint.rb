# frozen_string_literal: true

require "json"
require "vroxy/safe_query/errors"
require "vroxy/safe_query/signature"
require "vroxy/safe_query/nonce_store"
require "vroxy/safe_query/runner"

module Vroxy
  module SafeQuery
    class Endpoint
      HEADERS = {
        "content-type"  => "application/json",
        "cache-control" => "no-store"
      }.freeze

      TIMESTAMP_HEADER = "HTTP_X_VROXY_TIMESTAMP"
      NONCE_HEADER     = "HTTP_X_VROXY_NONCE"
      SIGNATURE_HEADER = "HTTP_X_VROXY_SIGNATURE"

      def self.call(env)
        new.call(env)
      end

      def call(env)
        config = Vroxy.configuration.safe_query
        return json(404, "not found") unless config.enabled?
        return json(405, "method not allowed") unless env["REQUEST_METHOD"].to_s.casecmp("POST").zero?

        body = read_body(env, Config::MAX_BODY_BYTES)
        return json(413, "request body too large") if body.nil?

        denial = authenticate(config, env, body)
        return json(401, denial) if denial

        unless config.rate_limiter.allow?(config.max_requests_per_minute)
          return json(429, "rate limit exceeded")
        end

        payload = parse_json(body)
        return json(400, "body must be a JSON object") unless payload.is_a?(Hash)
        return respond(200, config.describe) if payload["describe"]

        result = Runner.execute(payload, config: config)
        respond(result["ok"] ? 200 : 422, result)
      rescue StandardError => e
        warn "[vroxy] safe_query endpoint error: #{e.class}: #{e.message}"
        json(500, "internal error")
      end

      private

      def authenticate(config, env, body)
        timestamp = env[TIMESTAMP_HEADER].to_s
        nonce     = env[NONCE_HEADER].to_s
        signature = env[SIGNATURE_HEADER].to_s

        return "missing signature headers" if timestamp.empty? || nonce.empty? || signature.empty?

        unless Signature.fresh_timestamp?(timestamp, tolerance: config.timestamp_tolerance)
          return "timestamp outside the accepted window"
        end

        verified = Signature.verify(
          secret: config.secret, timestamp: timestamp, nonce: nonce,
          body: body, signature: signature
        )
        return "signature mismatch" unless verified

        fresh = Nonce.fresh?(config.nonce_store, nonce, ttl: config.timestamp_tolerance)
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

      def json(status, message)
        respond(status, { "ok" => false, "error" => message })
      end

      def respond(status, payload)
        [ status, HEADERS.dup, [ JSON.generate(payload) ] ]
      end
    end
  end
end
