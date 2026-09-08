# frozen_string_literal: true

require "openssl"
require "vroxy/safe_query/errors"

module Vroxy
  module SafeQuery
    module Signature
      module_function

      VERSION      = "v1"
      PREFIX       = "vroxy:query:v1"
      SEPARATOR    = "\n"
      NONCE_RE     = /\A[A-Za-z0-9_.\-]{8,128}\z/
      TIMESTAMP_RE = /\A\d{1,12}\z/
      HEX_RE       = /\A[0-9a-f]{64}\z/

      def canonical_string(timestamp:, nonce:, body:)
        ts = timestamp.to_s
        nc = nonce.to_s

        unless ts.match?(TIMESTAMP_RE)
          raise ArgumentError, "vroxy safe_query timestamp must be unix seconds, got #{ts.inspect}"
        end
        unless nc.match?(NONCE_RE)
          raise ArgumentError,
                "vroxy safe_query nonce must be 8-128 chars of [A-Za-z0-9_.-], got #{nc.inspect}"
        end

        [ PREFIX.b, ts.b, nc.b, body.to_s.b ].join(SEPARATOR.b)
      end

      def sign(secret:, timestamp:, nonce:, body:)
        raise ArgumentError, "vroxy safe_query secret is required to sign" if secret.to_s.empty?

        digest = OpenSSL::HMAC.hexdigest(
          "SHA256", secret.to_s, canonical_string(timestamp: timestamp, nonce: nonce, body: body)
        )
        "#{VERSION}=#{digest}"
      end

      def verify(secret:, timestamp:, nonce:, body:, signature:)
        given = signature.to_s
        return false unless given.start_with?("#{VERSION}=")
        return false unless given.delete_prefix("#{VERSION}=").match?(HEX_RE)

        expected = sign(secret: secret, timestamp: timestamp, nonce: nonce, body: body)
        return false unless given.bytesize == expected.bytesize

        OpenSSL.fixed_length_secure_compare(given.b, expected.b)
      rescue ArgumentError
        false
      end

      def fresh_timestamp?(timestamp, tolerance:, now: Time.now.to_i)
        return false unless timestamp.to_s.match?(TIMESTAMP_RE)
        (now - timestamp.to_i).abs <= tolerance.to_i
      end
    end
  end
end
