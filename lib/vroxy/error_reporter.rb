# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "time"

module Vroxy
  # Ships exceptions from the host app to vroxy's /ingest/errors
  # endpoint (public-key authenticated).  Reporting must never hurt
  # the host: delivery is async with short timeouts, every path
  # swallows its own failures, and an in-process throttle caps the
  # send rate.
  module ErrorReporter
    module_function

    MAX_PER_MINUTE = 60
    MAX_BACKTRACE_LINES = 30
    MAX_MESSAGE_CHARS = 1_000

    @mutex = Mutex.new
    @window_start = nil
    @window_count = 0

    class << self
      # Overridable delivery for tests / custom transports:
      # `->(payload, config) { ... }`.  Default posts via HTTP on a
      # background thread.
      attr_accessor :transport
    end

    def report(exception, context: {}, source: "ruby", handled: true)
      config = Vroxy.configuration
      return false unless config.report_errors?
      return false if config.endpoint.to_s.strip.empty?
      return false unless exception.respond_to?(:message)
      return false if ignored?(exception, config)
      return false if throttled?

      payload = build_payload(exception, context: context, source: source, handled: handled)
      (ErrorReporter.transport || DEFAULT_TRANSPORT).call(payload, config)
      true
    rescue StandardError
      false
    end

    def build_payload(exception, context:, source:, handled:)
      {
        source: source,
        error_class: exception.class.name,
        message: exception.message.to_s[0, MAX_MESSAGE_CHARS],
        backtrace: Array(exception.backtrace).first(MAX_BACKTRACE_LINES),
        environment: detect_environment,
        occurred_at: Time.now.utc.iso8601,
        context: normalize_context(context).merge("handled" => handled)
      }
    end

    def ignored?(exception, config)
      names = Array(config.error_ignore).map(&:to_s)
      exception.class.ancestors.any? { |klass| names.include?(klass.name) }
    end

    def throttled?
      @mutex.synchronize do
        now = Time.now.to_i
        if @window_start.nil? || now - @window_start >= 60
          @window_start = now
          @window_count = 0
        end
        @window_count += 1
        @window_count > MAX_PER_MINUTE
      end
    end

    def reset_throttle!
      @mutex.synchronize do
        @window_start = nil
        @window_count = 0
      end
    end

    def normalize_context(context)
      return {} unless context.is_a?(Hash)
      context.each_with_object({}) do |(k, v), out|
        out[k.to_s] = v.is_a?(Hash) || v.is_a?(Array) ? v : v.to_s
      end
    rescue StandardError
      {}
    end

    def detect_environment
      return Rails.env.to_s if defined?(Rails) && Rails.respond_to?(:env)
      ENV["RACK_ENV"] || ENV["RAILS_ENV"]
    end

    DEFAULT_TRANSPORT = lambda do |payload, config|
      Thread.new do
        uri = URI.parse("#{config.endpoint.chomp('/')}/ingest/errors")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 3
        http.read_timeout = 3

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["X-Vroxy-Tenant"] = config.api_key.to_s
        request.body = JSON.generate(payload)

        http.request(request)
      rescue StandardError => e
        warn "[vroxy] error report failed: #{e.class}: #{e.message}"
      end
    end
  end

  # Rails 7+ error-reporting integration: `Rails.error.subscribe`
  # hands us every unhandled request/job exception (and anything
  # apps report via `Rails.error.report`) — no rescue middleware
  # needed.
  class ErrorSubscriber
    def report(error, handled:, severity:, context: {}, source: nil)
      return if source.to_s.start_with?("vroxy")
      ctx = context.is_a?(Hash) ? context.dup : {}
      ctx[:rails_source] = source if source
      ctx[:severity] = severity if severity
      Vroxy::ErrorReporter.report(error, context: ctx, handled: handled)
    rescue StandardError
      nil
    end
  end

  def self.report_error(exception, context: {})
    ErrorReporter.report(exception, context: context)
  end
end
