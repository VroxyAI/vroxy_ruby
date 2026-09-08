# frozen_string_literal: true

require "vroxy/safe_query/nonce_store"

module Vroxy
  module SafeQuery
    module BootCheck
      QUIET_ENVIRONMENTS    = %w[development test].freeze
      PER_PROCESS_STORES    = %w[ActiveSupport::Cache::MemoryStore ActiveSupport::Cache::NullStore].freeze
      PER_HOST_STORES       = %w[ActiveSupport::Cache::FileStore].freeze
      WORKER_ENV_KEYS       = %w[WEB_CONCURRENCY PUMA_WORKERS].freeze
      FIX = "Fix: config.safe_query.nonce_store = Rails.cache, pointed at a store every " \
            "process shares (Redis or Memcached)."
      ACK = "If exactly one process serves that path, say so with " \
            "config.safe_query.single_process = true and this warning goes away."

      module_function

      def reset!
        @warned = false
      end

      def warned?
        @warned ||= false
      end

      def run(config:, env:, logger: nil, workers: worker_count)
        return nil if warned?

        message = message_for(config: config, env: env, workers: workers)
        return nil if message.nil?

        @warned = true
        emit(logger, message)
        message
      end

      def message_for(config:, env:, workers: nil)
        return nil unless config.respond_to?(:enabled?) && config.enabled?
        return nil if QUIET_ENVIRONMENTS.include?(env.to_s)

        reach = store_reach(config.nonce_store)
        return nil if reach == :shared
        return nil if reach != :none && config.single_process

        window = config.timestamp_tolerance
        path   = config.path

        case reach
        when :none    then no_defence_message(window)
        when :host    then per_host_message(config.nonce_store, window, path, workers)
        else               per_process_message(config.nonce_store, window, path, workers)
        end
      end

      def store_reach(store)
        return :none if store.nil?
        return :process if store.is_a?(NonceStore)

        name = store.class.name.to_s
        return :process if PER_PROCESS_STORES.include?(name)
        return :host if PER_HOST_STORES.include?(name)
        return :shared if store.respond_to?(:fresh?) || store.respond_to?(:write)

        :process
      end

      def worker_count
        WORKER_ENV_KEYS.each do |key|
          raw = ENV[key].to_s.strip
          return raw.to_i if raw.match?(/\A\d+\z/)
        end

        return nil unless defined?(::Puma) && ::Puma.respond_to?(:cli_config)

        options = ::Puma.cli_config&.options
        count   = options.respond_to?(:[]) ? options[:workers] : nil
        count.is_a?(Integer) ? count : nil
      rescue StandardError
        nil
      end

      def no_defence_message(window)
        "[vroxy] safe_query nonce_store is nil, so replay defence is OFF everywhere: one captured " \
        "signed request can be replayed against your database for the whole #{window}s freshness " \
        "window, on one process or a hundred. #{FIX}"
      end

      def per_host_message(store, window, path, workers)
        "[vroxy] safe_query replay defence is a #{store.class.name}, which is shared between the " \
        "workers on one host but not between hosts — a nonce burned on one host is still fresh on " \
        "the next. #{exposure(window, path, workers)} #{FIX} #{ACK}"
      end

      def per_process_message(store, window, path, workers)
        assigned = store.is_a?(NonceStore) ? "" : "nonce_store is a #{store.class.name}, which keeps " \
                                                  "its entries per-process, so assigning it did not make " \
                                                  "replay defence shared. "

        "[vroxy] safe_query replay defence is in-process. #{assigned}#{exposure(window, path, workers)} " \
        "#{FIX}#{known_multi_process?(workers) ? '' : " #{ACK}"}"
      end

      def exposure(window, path, workers)
        if known_multi_process?(workers)
          "This app is configured for #{workers} web workers, so a signed request replayed inside the " \
          "#{window}s freshness window is accepted by any worker that has not yet seen its nonce."
        else
          "This process cannot see how many others serve #{path} — the worker count and the " \
          "replica/dyno count both live outside it — so the warning cannot be sharper than this: if " \
          "more than one process serves that path, a signed request replayed inside the #{window}s " \
          "freshness window is accepted by whichever process has not yet seen its nonce."
        end
      end

      def known_multi_process?(workers)
        workers.is_a?(Integer) && workers > 1
      end

      def emit(logger, message)
        if logger.respond_to?(:warn)
          logger.warn(message)
        else
          Kernel.warn(message)
        end
      rescue StandardError
        nil
      end
    end
  end
end
