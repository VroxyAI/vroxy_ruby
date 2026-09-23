# frozen_string_literal: true

module Vroxy
  module Tools
    class Registry
      def initialize
        @tools = {}
      end

      def register(definition)
        definition.validate!
        @tools[definition.name] = definition
        definition
      end

      def [](name)
        @tools[name.to_s]
      end

      def fetch(name)
        tool = self[name]
        raise KeyError, "unknown vroxy tool #{name.inspect}" unless tool
        tool
      end

      def all
        @tools.values
      end

      def names
        @tools.keys
      end

      def host_tools
        all.select { |t| t.resolved_kind == "host" }
      end

      def clear!
        @tools.clear
      end

      def empty?
        @tools.empty?
      end
    end
  end
end
