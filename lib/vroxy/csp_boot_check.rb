# frozen_string_literal: true

require "uri"

module Vroxy
  # Warn at boot when the host app runs a strict CSP but the chat
  # widget's live websocket (`wss://<endpoint>/cable`) has no reason to
  # be allowed — the visitor's widget sits on "Reconnecting…" and only
  # the host developer can fix their connect-src.  Keyed on `csp_nonce`
  # being set, which is the marker that the host chose a strict CSP.
  module CspBootCheck
    QUIET_ENVIRONMENTS = %w[development test].freeze
    DOC_LINK = "https://github.com/wartron/vroxy_ruby#content-security-policy".freeze

    module_function

    def wss_origin(endpoint)
      uri = URI.parse(endpoint.to_s)
      return nil if uri.host.to_s.empty?

      "wss://#{uri.host}"
    rescue URI::Error
      nil
    end

    def message_for(config:, env:)
      return nil unless config.respond_to?(:csp_nonce) && !config.csp_nonce.nil?
      return nil if QUIET_ENVIRONMENTS.include?(env.to_s)

      origin = wss_origin(config.endpoint)
      return nil if origin.nil?

      "[vroxy] strict CSP detected (csp_nonce is set): add #{origin} to connect-src, or the chat " \
        "widget can't open its live websocket and will sit on \"Reconnecting…\". See #{DOC_LINK}"
    end

    def run(config:, env:, logger: nil)
      message = message_for(config: config, env: env)
      return nil if message.nil?

      if logger.respond_to?(:warn)
        logger.warn(message)
      else
        Kernel.warn(message)
      end
      message
    rescue StandardError
      nil
    end
  end
end
