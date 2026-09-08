# frozen_string_literal: true

module Vroxy
  module SafeQuery
    class RateLimiter
      WINDOW_SECONDS = 60

      def initialize
        @mutex        = Mutex.new
        @window_start = nil
        @count        = 0
      end

      def allow?(limit, now: Time.now.to_i)
        return false if limit.to_i <= 0

        @mutex.synchronize do
          if @window_start.nil? || now - @window_start >= WINDOW_SECONDS
            @window_start = now
            @count        = 0
          end
          @count += 1
          @count <= limit.to_i
        end
      end

      def reset!
        @mutex.synchronize do
          @window_start = nil
          @count        = 0
        end
      end
    end
  end
end
