# frozen_string_literal: true

module Vroxy
  # Rack middleware that appends the vroxy snippet to HTML
  # responses.  Deliberately conservative — we only touch a
  # response when ALL of these hold:
  #
  #   * Vroxy is enabled (api_key present, not force-disabled).
  #   * `config.auto_inject` is true.
  #   * The request path isn't on `config.exclude_paths`.
  #   * The response Content-Type is text/html (case-insensitive).
  #   * The status is a 2xx render (not 3xx redirect, not 304, not 5xx error).
  #   * Body contains a literal `</body>` we can splice before.
  #   * The helper wasn't already used on this request.
  #
  # Any failure to meet those bounces us out of the way; the
  # original response passes through untouched.
  class Middleware
    HTML_CT       = /\Atext\/html\b/i.freeze
    BODY_CLOSE_RE = /<\/body>/i.freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [status, headers, body] unless should_inject?(env, status, headers)

      html = read_body(body)
      return [status, headers, body] unless html && html.match?(BODY_CLOSE_RE)

      # Build the snippet via the same code path the helper uses.
      # `env["action_controller.instance"]` is the request's
      # controller instance — Rails stashes it on every dispatch
      # so middleware can introspect. Nil for non-AC endpoints
      # (mounted Sinatra, Rack apps) — we still inject the loader
      # tag; identify just no-ops without a controller to sniff.
      controller = env["action_controller.instance"]
      snippet    = Vroxy::Snippet.render(controller_proxy(controller))
      return [status, headers, body] if snippet.empty?

      new_html = html.sub(BODY_CLOSE_RE) { |m| "#{snippet}#{m}" }
      new_body = [new_html]
      new_headers = headers.dup
      # Same-case update — a plain-Hash response (mounted Rack app)
      # with Rack-3 lowercase "content-length" must not grow a
      # SECOND capitalized header with a stale byte count.
      cl_key = [ "content-length", "Content-Length" ].find { |k| new_headers.key?(k) }
      new_headers[cl_key] = new_html.bytesize.to_s if cl_key

      close_body(body)
      [status, new_headers, new_body]
    end

    private

    def should_inject?(env, status, headers)
      config = Vroxy.configuration
      return false unless config.enabled?
      return false unless config.auto_inject
      return false if env[Helper::RENDERED_ENV_KEY]
      return false if config.excluded?(env["PATH_INFO"].to_s)
      return false unless (200..299).cover?(status.to_i)
      return false if status.to_i == 204

      ct = header(headers, "Content-Type") || header(headers, "content-type")
      ct.to_s.match?(HTML_CT)
    end

    # Rack 3 lowercases header names; Rack 2 preserves the classic
    # capitalization.  Look under both without allocating a full
    # normalized hash on the hot path.
    def header(headers, name)
      headers[name] || headers[name.downcase]
    end

    def read_body(body)
      buffer = +""
      body.each { |part| buffer << part.to_s }
      buffer
    rescue StandardError
      nil
    end

    def close_body(body)
      body.close if body.respond_to?(:close)
    end

    # Wrap a nil controller so Snippet.render / Identity.resolve can
    # call `.respond_to?(:current_user)` without a NoMethodError.
    # For real controllers this is a passthrough.
    def controller_proxy(controller)
      controller || NullController
    end

    module NullController
      module_function

      def respond_to?(_method, _include_private = false)
        false
      end
    end
  end
end
