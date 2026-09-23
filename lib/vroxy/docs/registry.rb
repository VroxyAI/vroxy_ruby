# frozen_string_literal: true

module Vroxy
  module Docs
    class Registry
      def initialize
        @docs = {}
      end

      def register(definition)
        definition.validate!
        @docs[definition.slug] = definition
        definition
      end

      def all
        @docs.values
      end

      def clear!
        @docs.clear
      end

      def empty?
        @docs.empty?
      end
    end
  end
end
