# frozen_string_literal: true

module Vroxy
  module SafeQuery
    class NonceStore
      DEFAULT_MAX_ENTRIES = 8_192

      def initialize(max_entries: DEFAULT_MAX_ENTRIES)
        @max_entries = max_entries
        @seen        = {}
        @mutex       = Mutex.new
      end

      def fresh?(nonce, ttl:, now: Time.now.to_f)
        key = nonce.to_s
        @mutex.synchronize do
          @seen.delete_if { |_, expires_at| expires_at <= now }
          return false if @seen.key?(key)

          @seen.shift while @seen.size >= @max_entries
          @seen[key] = now + ttl.to_f
          true
        end
      end

      def clear!
        @mutex.synchronize { @seen.clear }
      end

      def size
        @mutex.synchronize { @seen.size }
      end
    end

    module Nonce
      module_function

      def fresh?(store, nonce, ttl:)
        return true if store.nil?
        return store.fresh?(nonce, ttl: ttl) if store.respond_to?(:fresh?)
        return !!store.write("vroxy:safe_query:nonce:#{nonce}", true, expires_in: ttl, unless_exist: true) if store.respond_to?(:write)

        true
      end
    end
  end
end
