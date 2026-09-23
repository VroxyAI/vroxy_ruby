# frozen_string_literal: true

module Vroxy
  module Tools
    class Definition
      NAME_RE = /\A[a-z][a-z0-9_]{1,39}\z/
      KINDS   = %w[link fetch host].freeze
      ACCESS  = %w[public user admin].freeze

      attr_reader :name, :description, :label, :kind, :access, :url_template,
                  :params, :handler, :enabled, :follow_origin

      def initialize(name)
        @name          = name.to_s
        @description   = nil
        @label         = ""
        @kind          = nil
        @access        = "public"
        @url_template  = nil
        @params        = []
        @handler       = nil
        @enabled       = true
        @follow_origin = false
      end

      def description(value = nil)
        return @description if value.nil?
        @description = value.to_s
      end

      def label(value = nil)
        return @label if value.nil?
        @label = value.to_s
      end

      def kind(value = nil)
        return @kind if value.nil?
        @kind = value.to_s
      end

      def access(value = nil)
        return @access if value.nil?
        @access = value.to_s
      end

      def url_template(value = nil)
        return @url_template if value.nil?
        @url_template = value.to_s
      end

      def enabled(value = nil)
        return @enabled if value.nil?
        @enabled = !!value
      end

      def follow_origin(value = nil)
        return @follow_origin if value.nil?
        @follow_origin = !!value
      end

      def param(name, description = "", required: false)
        @params << {
          "name"        => name.to_s,
          "description" => description.to_s,
          "required"    => !!required
        }
      end

      def handle(&block)
        raise ArgumentError, "tool #{@name.inspect} handle requires a block" unless block
        @handler = block
        @kind ||= "host"
      end

      def resolved_kind
        return @kind if @kind
        return "host" if @handler
        "link"
      end

      def validate!
        raise ArgumentError, "tool name #{@name.inspect} is invalid" unless @name.match?(NAME_RE)
        raise ArgumentError, "tool #{@name} needs a description" if @description.to_s.strip.empty?
        unless ACCESS.include?(@access)
          raise ArgumentError, "tool #{@name} access must be one of #{ACCESS.join(', ')}"
        end
        k = resolved_kind
        unless KINDS.include?(k)
          raise ArgumentError, "tool #{@name} kind must be one of #{KINDS.join(', ')}"
        end
        if k == "host"
          raise ArgumentError, "tool #{@name} (host) needs a handle { } block" unless @handler
        else
          if @url_template.to_s.strip.empty?
            raise ArgumentError, "tool #{@name} (#{k}) needs a url_template"
          end
        end
        self
      end

      def sync_payload
        payload = {
          "name"          => @name,
          "label"         => @label.to_s,
          "description"   => @description.to_s,
          "kind"          => resolved_kind,
          "access"        => @access,
          "enabled"       => @enabled,
          "follow_origin" => @follow_origin,
          "params"        => @params
        }
        payload["url_template"] = @url_template if resolved_kind != "host"
        payload
      end

      def call(arguments)
        raise "tool #{@name} has no handler" unless @handler
        @handler.call(stringify(arguments))
      end

      private

      def stringify(arguments)
        (arguments || {}).each_with_object({}) do |(key, value), out|
          out[key.to_s] = value
        end
      end
    end
  end
end
