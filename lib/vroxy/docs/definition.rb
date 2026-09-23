# frozen_string_literal: true

module Vroxy
  module Docs
    class Definition
      SLUG_RE = /\A[a-z0-9][a-z0-9_-]{0,63}\z/

      attr_reader :slug, :title, :folder_path, :position, :status, :body_md

      def initialize(title, slug: nil, folder: "", position: 0, status: :published)
        @title       = title.to_s
        @slug        = (slug || title).to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        @folder_path = folder.to_s
        @position    = position.to_i
        @status      = status.to_s
        @body_md     = nil
      end

      def body(value = nil, &block)
        if block
          @body_md = block.call.to_s
          return @body_md
        end
        return @body_md if value.nil?
        @body_md = value.to_s
      end

      def validate!
        raise ArgumentError, "doc title can't be blank" if @title.strip.empty?
        raise ArgumentError, "doc slug #{@slug.inspect} is invalid" unless @slug.match?(SLUG_RE)
        raise ArgumentError, "doc #{@slug} needs a body" if @body_md.to_s.strip.empty?
        unless %w[draft published].include?(@status)
          raise ArgumentError, "doc status must be draft or published"
        end
        self
      end

      def marker
        "seeded:gem:#{@slug}"
      end

      def sync_payload
        {
          "title"       => @title,
          "body_md"     => @body_md,
          "folder_path" => @folder_path,
          "position"    => @position,
          "status"      => @status,
          "notes"       => marker
        }
      end
    end
  end
end
