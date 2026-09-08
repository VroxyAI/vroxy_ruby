# frozen_string_literal: true

module Vroxy
  module SafeQuery
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class QueryError < Error; end
  end
end
