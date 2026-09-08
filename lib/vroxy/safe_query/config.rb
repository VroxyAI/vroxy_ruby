# frozen_string_literal: true

require "vroxy/safe_query/errors"
require "vroxy/safe_query/allowlist"
require "vroxy/safe_query/nonce_store"
require "vroxy/safe_query/rate_limiter"

module Vroxy
  module SafeQuery
    class Config
      DEFAULT_PATH                = "/vroxy/query"
      DEFAULT_ROWS                = 50
      DEFAULT_MAX_ROWS            = 200
      ABSOLUTE_MAX_ROWS           = 1_000
      MIN_SECRET_LENGTH           = 32
      DEFAULT_TOLERANCE           = 300
      MAX_TOLERANCE               = 900
      DEFAULT_REQUESTS_PER_MINUTE = 60
      MAX_BODY_BYTES              = 16_384
      MAX_STEPS                   = 20
      PATH_RE                     = %r{\A/[A-Za-z0-9\-_/.]*\z}

      attr_reader :secret, :path, :rules, :max_rows, :default_rows,
                  :timestamp_tolerance, :max_requests_per_minute,
                  :rate_limiter
      attr_accessor :nonce_store
      attr_writer :enabled, :single_process

      def initialize
        @rules                   = {}
        @path                    = DEFAULT_PATH
        @max_rows                = DEFAULT_MAX_ROWS
        @default_rows            = DEFAULT_ROWS
        @timestamp_tolerance     = DEFAULT_TOLERANCE
        @max_requests_per_minute = DEFAULT_REQUESTS_PER_MINUTE
        @enabled                 = nil
        @single_process          = false
        @nonce_store             = NonceStore.new
        @rate_limiter            = RateLimiter.new
        @secret                  = secret_from_env
      end

      def model(name, columns:, scope: nil, max_rows: nil)
        rule = ModelRule.new(name, columns: columns, scope: scope, max_rows: max_rows)
        @rules[rule.model_name] = rule
      end

      def rule_for(name)
        @rules[name.to_s]
      end

      def model_names
        @rules.keys
      end

      def secret=(value)
        raw = value.to_s
        if raw.empty?
          @secret = nil
          return
        end

        if raw.length < MIN_SECRET_LENGTH
          raise ConfigurationError,
                "vroxy safe_query secret must be at least #{MIN_SECRET_LENGTH} characters — " \
                "it authenticates reads against your production database"
        end

        @secret = raw
      end

      def path=(value)
        raw = value.to_s
        raise ConfigurationError, "vroxy safe_query path must look like \"/vroxy/query\"" unless raw.match?(PATH_RE)

        @path = raw.length > 1 ? raw.chomp("/") : raw
      end

      def max_rows=(value)
        @max_rows     = clamp_integer(value, 1, ABSOLUTE_MAX_ROWS, "max_rows")
        @default_rows = @max_rows if @default_rows > @max_rows
      end

      def default_rows=(value)
        @default_rows = clamp_integer(value, 1, @max_rows, "default_rows")
      end

      def timestamp_tolerance=(value)
        @timestamp_tolerance = clamp_integer(value, 1, MAX_TOLERANCE, "timestamp_tolerance")
      end

      def max_requests_per_minute=(value)
        @max_requests_per_minute = clamp_integer(value, 0, 10_000, "max_requests_per_minute")
      end

      def configured?
        !@secret.to_s.empty? && @rules.any?
      end

      def enabled?
        return false unless configured?
        return true if @enabled.nil?

        !!@enabled
      end

      def single_process
        !!@single_process
      end

      def max_rows_for(rule)
        [ rule.max_rows || max_rows, max_rows ].min
      end

      def default_rows_for(rule)
        [ rule.max_rows || default_rows, max_rows_for(rule) ].min
      end

      def describe
        {
          "ok"      => true,
          "models"  => @rules.values.map(&:describe),
          "grammar" => {
            "scope_steps" => Runner::SCOPE_STEPS,
            "terminals"   => Runner::TERMINALS,
            "max_rows"    => max_rows,
            "default_rows" => default_rows,
            "max_steps"   => MAX_STEPS
          }
        }
      end

      private

      def secret_from_env
        raw = ENV["VROXY_QUERY_SECRET"].to_s
        return nil if raw.empty?

        if raw.length < MIN_SECRET_LENGTH
          warn "[vroxy] VROXY_QUERY_SECRET is shorter than #{MIN_SECRET_LENGTH} characters — " \
               "safe_query stays disabled"
          return nil
        end

        raw
      end

      def clamp_integer(value, low, high, label)
        int = Integer(value)
        int.clamp(low, high)
      rescue ArgumentError, TypeError
        raise ConfigurationError, "vroxy safe_query #{label} must be an integer"
      end
    end
  end
end
