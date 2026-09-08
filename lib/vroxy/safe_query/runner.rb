# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"
require "vroxy/safe_query/errors"

module Vroxy
  module SafeQuery
    module Runner
      module_function

      SCOPE_STEPS = %w[where where_not order limit offset group].freeze
      TERMINALS   = %w[count sum average minimum maximum pluck first last to_a exists?].freeze
      ROW_TERMINALS = %w[pluck to_a].freeze
      COLUMN_TERMINALS = %w[sum average minimum maximum].freeze
      DIRECTIONS  = %w[asc desc].freeze

      REL_TIME_RE = /\A(\d+)\.(second|minute|hour|day|week|month|year)s?\.(ago|from_now)\z/
      DATE_RE     = /\A\d{4}-\d{2}-\d{2}/
      COMPARISON_RE = /\A(.+?)_(gt|gte|lt|lte)\z/

      DURATION_UNITS = {
        "second" => :seconds, "minute" => :minutes, "hour" => :hours,
        "day" => :days, "week" => :weeks, "month" => :months, "year" => :years
      }.freeze

      MAX_STRING_CHARS = 500
      MAX_OFFSET       = 100_000
      MAX_ERROR_CHARS  = 300

      def execute(payload, config: Vroxy.configuration.safe_query)
        payload = stringify(payload)
        return err("payload must be a JSON object") unless payload.is_a?(Hash)
        return err("ActiveRecord is not available in this application") unless defined?(::ActiveRecord::Base)

        model_name = payload["model"].to_s
        return err("`model` is required") if model_name.empty?

        rule = config.rule_for(model_name)
        unless rule
          return err("Model #{model_name.inspect} is not exposed to vroxy. " \
                     "Allowed: #{config.model_names.join(', ')}")
        end

        terminal = payload["terminal"].to_s
        return err("`terminal` is required") if terminal.empty?
        unless TERMINALS.include?(terminal)
          return err("Terminal #{terminal.inspect} not allowed. Allowed: #{TERMINALS.join(', ')}")
        end

        steps = payload["scope"] || []
        return err("`scope` must be an array of single-key step hashes") unless steps.is_a?(Array)
        if steps.length > Config::MAX_STEPS
          return err("`scope` may hold at most #{Config::MAX_STEPS} steps")
        end

        run(rule, config, steps, terminal, payload["terminal_args"])
      end

      def run(rule, config, steps, terminal, terminal_args)
        sql_captured = nil
        result       = nil

        ::ActiveRecord::Base.transaction(requires_new: true) do
          relation = rule.base_relation
          klass    = relation.klass

          steps.each_with_index do |step, index|
            relation = apply_step!(rule, klass, config, relation, step, index)
          end

          relation = enforce_row_cap(rule, config, relation, terminal)
          sql_captured = safe_to_sql(relation)
          value = json_safe(invoke_terminal!(rule, klass, relation, terminal, terminal_args))
          result = { "ok" => true, "result" => value, "sql" => sql_captured }

          raise ::ActiveRecord::Rollback
        end

        result || err("no result produced", sql: sql_captured)
      rescue QueryError => e
        err(e.message, sql: sql_captured)
      rescue ::ActiveRecord::StatementInvalid => e
        err("SQL error: #{truncate(e.message)}", sql: sql_captured)
      rescue StandardError => e
        err("#{e.class}: #{truncate(e.message)}", sql: sql_captured)
      end

      def apply_step!(rule, klass, config, relation, step, index)
        unless step.is_a?(Hash) && step.size == 1
          raise QueryError, "step ##{index} must be a hash with exactly one key"
        end

        method, arg = step.first
        method = method.to_s
        unless SCOPE_STEPS.include?(method)
          raise QueryError, "step ##{index} method #{method.inspect} not allowed. Allowed: #{SCOPE_STEPS.join(', ')}"
        end

        case method
        when "where"     then apply_where(rule, klass, relation, arg)
        when "where_not" then apply_where_not(rule, klass, relation, arg)
        when "order"     then relation.order(build_order(rule, klass, arg))
        when "limit"     then relation.limit(clamp(arg, 1, config.max_rows_for(rule)))
        when "offset"    then relation.offset(clamp(arg, 0, MAX_OFFSET))
        when "group"     then relation.group(checked_columns!(rule, klass, Array(arg), "group"))
        end
      end

      def apply_where(rule, klass, relation, arg)
        raise QueryError, "`where` arg must be a hash" unless arg.is_a?(Hash)

        arg.each do |raw_key, raw_value|
          key   = raw_key.to_s
          value = coerce_value(raw_value)
          match = key.match(COMPARISON_RE)

          if rule.allows?(klass, key)
            assert_castable!(rule, klass, key, value)
            relation = relation.where(key => value)
          elsif match && rule.allows?(klass, match[1])
            assert_castable!(rule, klass, match[1], value)
            relation = relation.where(comparison_node(klass, match[1], match[2], value))
          else
            raise QueryError, refusal("where", key, rule)
          end
        end

        relation
      end

      def apply_where_not(rule, klass, relation, arg)
        raise QueryError, "`where_not` arg must be a hash" unless arg.is_a?(Hash)

        arg.each do |raw_key, raw_value|
          key = raw_key.to_s
          unless rule.allows?(klass, key)
            raise QueryError,
                  "#{refusal('where_not', key, rule)} " \
                  "(comparison suffixes are `where`-only — invert the operator instead)"
          end

          value = coerce_value(raw_value)
          assert_castable!(rule, klass, key, value)
          relation = relation.where.not(key => value)
        end

        relation
      end

      def comparison_node(klass, column, operator, value)
        attribute = klass.arel_table[column]
        case operator
        when "gt"  then attribute.gt(value)
        when "gte" then attribute.gteq(value)
        when "lt"  then attribute.lt(value)
        when "lte" then attribute.lteq(value)
        end
      end

      def build_order(rule, klass, arg)
        case arg
        when String
          column, direction = arg.split(/\s+/, 2)
          checked_columns!(rule, klass, [ column ], "order")
          { column.to_s => direction_for(direction) }
        when Hash
          arg.each_with_object({}) do |(column, direction), out|
            checked_columns!(rule, klass, [ column.to_s ], "order")
            out[column.to_s] = direction_for(direction)
          end
        else
          raise QueryError, "`order` arg must be a string like 'created_at desc' or a hash"
        end
      end

      def direction_for(direction)
        return :asc if direction.nil?

        value = direction.to_s.strip.downcase
        return :asc if value.empty?
        unless DIRECTIONS.include?(value)
          raise QueryError, "`order` direction #{direction.to_s.inspect} not allowed. Allowed: #{DIRECTIONS.join(', ')}"
        end

        value.to_sym
      end

      def enforce_row_cap(rule, config, relation, terminal)
        needs_cap = ROW_TERMINALS.include?(terminal) || relation.group_values.any?
        return relation unless needs_cap

        cap = config.max_rows_for(rule)
        return relation.limit(config.default_rows_for(rule)) if relation.limit_value.nil?
        return relation.limit(cap) if relation.limit_value.to_i > cap

        relation
      end

      def invoke_terminal!(rule, klass, relation, terminal, args)
        case terminal
        when "count"   then relation.count
        when "exists?" then relation.exists?
        when "first"   then shape_row(rule, relation.first)
        when "last"    then shape_row(rule, relation.last)
        when "to_a"    then relation.to_a.map { |record| shape_row(rule, record) }
        when "pluck"
          columns = Array(args).map(&:to_s)
          columns = [ "id" ] if columns.empty?
          checked_columns!(rule, klass, columns, "pluck")
          relation.pluck(*columns)
        when *COLUMN_TERMINALS
          column = Array(args).first.to_s
          raise QueryError, "#{terminal} needs a column name in terminal_args" if column.empty?

          checked_columns!(rule, klass, [ column ], terminal)
          relation.public_send(terminal, column)
        end
      end

      def checked_columns!(rule, klass, columns, context)
        list = columns.map(&:to_s)
        list.each do |column|
          raise QueryError, refusal(context, column, rule) unless rule.allows?(klass, column)
        end
        list
      end

      def refusal(context, column, rule)
        "#{context} column #{column.inspect} is not an allowed column of #{rule.model_name}. " \
          "Allowed: #{rule.columns.join(', ')}"
      end

      def assert_castable!(rule, klass, column, value)
        return if value.nil?

        type = klass.type_for_attribute(column.to_s)
        return if type.nil?

        elements = value.is_a?(Array) ? value : [ value ]
        elements.each do |element|
          next if element.nil?

          serialized = begin
            type.serialize(element)
          rescue StandardError
            nil
          end
          next unless serialized.nil?

          column_type = klass.columns_hash[column.to_s]&.type
          raise QueryError,
                "`where` value #{element.inspect} cannot be represented as " \
                "#{rule.model_name}.#{column} (a #{column_type} column) — " \
                "it would match NULL and wrongly return nothing."
        end
      end

      def coerce_value(value)
        case value
        when nil, true, false, Numeric then value
        when Array then value.map { |element| coerce_value(element) }
        when String then coerce_string(value)
        else
          raise QueryError, "value #{value.inspect} is not a supported primitive"
        end
      end

      def coerce_string(value)
        if (match = value.match(REL_TIME_RE))
          amount = match[1].to_i
          unit   = DURATION_UNITS.fetch(match[2])
          span   = ::ActiveSupport::Duration.public_send(unit, amount)
          return match[3] == "ago" ? span.ago : span.from_now
        end

        return parse_time(value) if value.match?(DATE_RE)

        value
      end

      def parse_time(value)
        if defined?(Time.zone) && Time.zone
          Time.zone.parse(value) || value
        else
          require "time"
          Time.parse(value)
        end
      rescue ArgumentError, TypeError
        value
      end

      def shape_row(rule, record)
        return nil if record.nil?

        rule.columns.each_with_object({}) do |column, out|
          next unless record.has_attribute?(column)

          value = record[column]
          out[column] = value.is_a?(String) ? value[0, MAX_STRING_CHARS] : value
        end
      end

      def json_safe(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), out| out[json_scalar(k).to_s] = json_safe(v) }
        when Array then value.map { |element| json_safe(element) }
        else json_scalar(value)
        end
      end

      def json_scalar(value)
        case value
        when Time, DateTime then value.iso8601
        when Date           then value.iso8601
        when BigDecimal     then value.to_f
        when String         then value[0, MAX_STRING_CHARS]
        else value
        end
      end

      def clamp(value, low, high)
        Integer(value).clamp(low, high)
      rescue ArgumentError, TypeError
        raise QueryError, "expected an integer, got #{value.inspect}"
      end

      def stringify(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify(v) }
        when Array then value.map { |element| stringify(element) }
        else value
        end
      end

      def safe_to_sql(relation)
        relation.to_sql
      rescue StandardError
        nil
      end

      def truncate(message)
        message.to_s[0, MAX_ERROR_CHARS]
      end

      def err(message, sql: nil)
        payload = { "ok" => false, "error" => message }
        payload["sql"] = sql if sql
        payload
      end
    end
  end
end
