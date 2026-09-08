# frozen_string_literal: true

require "vroxy/safe_query/errors"

module Vroxy
  module SafeQuery
    SECRET_COLUMN_RE = /password|secret|credential|api_key|(\A|_)token(\z|_)|_key\z|_digest\z|\Adigest\z/i
    MODEL_NAME_RE    = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/
    COLUMN_NAME_RE   = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    class ModelRule
      attr_reader :model_name, :columns, :scope, :max_rows

      def initialize(model_name, columns:, scope: nil, max_rows: nil)
        @model_name = model_name.to_s
        unless @model_name.match?(MODEL_NAME_RE)
          raise ConfigurationError,
                "safe_query model #{model_name.inspect} is not a Ruby constant name"
        end

        @columns = build_columns(columns)

        if scope && !scope.respond_to?(:call)
          raise ConfigurationError, "safe_query scope for #{@model_name} must respond to #call"
        end
        @scope = scope

        @max_rows = max_rows.nil? ? nil : positive_integer(max_rows, "max_rows")
      end

      def model_class
        klass = begin
          Object.const_get(model_name)
        rescue NameError
          raise QueryError,
                "#{model_name} is declared in vroxy safe_query but is not defined in this application"
        end

        unless klass.is_a?(Class) && active_record?(klass)
          raise QueryError, "#{model_name} is not an ActiveRecord model"
        end

        klass
      end

      def base_relation
        klass    = model_class
        relation = klass.all
        return relation unless scope

        scoped = scope.call(relation)
        unless scoped.is_a?(::ActiveRecord::Relation) && scoped.klass == klass
          raise QueryError,
                "safe_query scope for #{model_name} must return an ActiveRecord::Relation of #{model_name}"
        end
        scoped
      end

      def allows?(klass, column)
        col = column.to_s
        columns.include?(col) && !col.match?(SECRET_COLUMN_RE) && klass.column_names.include?(col)
      end

      def describe
        { "name" => model_name, "columns" => columns, "scoped" => !scope.nil? }
      end

      private

      def active_record?(klass)
        defined?(::ActiveRecord::Base) && klass < ::ActiveRecord::Base
      end

      def build_columns(columns)
        list = Array(columns).map(&:to_s)
        raise ConfigurationError, "safe_query model #{@model_name} needs at least one column" if list.empty?

        list.each do |col|
          unless col.match?(COLUMN_NAME_RE)
            raise ConfigurationError,
                  "safe_query column #{col.inspect} on #{@model_name} is not a plain column name"
          end

          next unless col.match?(SECRET_COLUMN_RE)

          raise ConfigurationError,
                "safe_query refuses column #{col.inspect} on #{@model_name} — it reads as a credential. " \
                "Expose a derived, non-secret column instead."
        end

        list.uniq.freeze
      end

      def positive_integer(value, label)
        int = Integer(value)
        raise ConfigurationError, "safe_query #{label} must be positive" unless int.positive?
        int
      rescue ArgumentError, TypeError
        raise ConfigurationError, "safe_query #{label} must be an integer"
      end
    end
  end
end
