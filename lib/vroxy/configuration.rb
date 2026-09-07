# frozen_string_literal: true

module Vroxy
  # Singleton config populated once at boot (typically from
  # `config/initializers/vroxy.rb`).  Kept intentionally small:
  # the widget itself is configured server-side on vroxy.ai — the
  # host-app config is just credentials + integration knobs.
  class Configuration
    # `pk_…` tenant public key.  Same value the customer sees on
    # their vroxy workspace settings page; safe to ship to the
    # browser (that's literally what happens — the widget URL
    # carries it as a query param).  Required.
    attr_accessor :api_key

    # Base URL of the vroxy deployment serving `/widget.js`.
    # Default targets prod; override for staging / self-hosted.
    attr_accessor :endpoint

    # Master kill switch.  `false` short-circuits the middleware
    # AND makes the helper render `""` — so a single flag flip
    # disables the widget without ripping the tag out of layouts.
    # Defaults to true when `api_key` is present, false otherwise;
    # host apps can force either way.
    attr_writer :enabled

    # When true (default), the Rack middleware rewrites HTML
    # responses to insert the snippet before `</body>`.  Set to
    # false if the host app wants to place `<%= vroxy_snippet %>`
    # by hand — e.g. inside a specific layout, or above a CSP
    # nonce'd block.
    attr_accessor :auto_inject

    # `->(controller) { { email:, name:, external_id:, role:, meta: } }`
    # Called on every request the middleware injects into (or that
    # renders the helper).  Return `nil` to skip identification for
    # this request (anonymous visitor).  Overrides the default
    # `current_user` sniffing when set.
    attr_accessor :identify

    # Optional CSP nonce lookup.  `->(controller) { controller.content_security_policy_nonce }`
    # if the app runs a strict CSP; otherwise leave nil and inline
    # `<script>` tags render without a nonce attribute.
    attr_accessor :csp_nonce

    # Paths (String or Regexp) that should NEVER get the snippet
    # even when auto_inject is on — e.g. admin dashboards, health
    # checks, API mounts that happen to return HTML.  Matched
    # against `request.path`.
    attr_accessor :exclude_paths

    # Role values that trigger the admin inspector.  When the
    # identity resolver returns a `role:` in this list, the
    # snippet emits a third `<script>` that dynamic-imports the
    # inspector bundle from `endpoint/admin_ui_inspector.js` and
    # boots it with the current request's controller/action +
    # tracked partial trail.  Non-admin identities never load the
    # inspector.
    attr_accessor :admin_roles

    # Tenant-owned vroxy API token (tenant:write) for
    # server-to-server calls — the glossary sync rake task.  NOT
    # the public api_key.  Reads ENV VROXY_SECRET_TOKEN.
    attr_accessor :secret_token

    # Exception reporting to vroxy (/ingest/errors, authenticated
    # by the public api_key).  Tri-state: nil (default) auto-enables
    # in production when an api_key is present; true/false force.
    attr_writer :report_errors

    # Exception class names never reported.  Matched against the
    # class AND its ancestors, so subclasses of an ignored class
    # stay ignored.
    attr_accessor :error_ignore

    def report_errors?
      return false if api_key.to_s.strip.empty?
      return @report_errors unless @report_errors.nil?
      Vroxy.production?
    end

    # Identity-verification secret from the vroxy workspace's
    # Embed page.  When set, the snippet signs the identify
    # payload's access claims (external_id / email / level) with
    # HMAC-SHA256 — that's what lets vroxy TRUST "this visitor
    # is a signed-in user / an admin" and unlock access-gated bot
    # tools for them.  Without it, identify still personalizes
    # the conversation but the visitor stays at public tool
    # access (an unsigned claim would let any visitor self-claim
    # admin from the console).  Server-side only — never ship it
    # to the browser yourself; the snippet only emits the derived
    # signature.  Reads ENV VROXY_IDENTITY_SECRET.
    attr_accessor :identity_secret

    # Optional: build an admin deep-link template for a glossary
    # term.  `->(model_key) { "https://myapp.com/admin/#{model_key}s/{id}" }`
    # — return nil to skip.  Literal "{id}" stays in the template;
    # vroxy fills it per record.
    attr_accessor :glossary_admin_url

    # Optional: extra glossary entries appended verbatim to the
    # i18n-derived ones — `[{ "term" => ..., "aliases" => [...] }]`.
    attr_accessor :glossary_extra

    def initialize
      @api_key       = ENV["VROXY_API_KEY"]
      @endpoint      = ENV.fetch("VROXY_ENDPOINT", "https://vroxy.ai")
      @auto_inject   = true
      @identify      = nil
      @csp_nonce     = nil
      @exclude_paths = []
      @admin_roles   = %w[admin owner]
      @secret_token  = ENV["VROXY_SECRET_TOKEN"]
      @identity_secret = ENV["VROXY_IDENTITY_SECRET"]
      @report_errors = nil
      @error_ignore  = %w[
        ActiveRecord::RecordNotFound
        ActionController::RoutingError
        ActionController::UnknownFormat
        ActionController::InvalidAuthenticityToken
        ActionController::BadRequest
        ActionDispatch::Http::MimeNegotiation::InvalidType
        AbstractController::ActionNotFound
        Rack::QueryParser::ParameterTypeError
      ]
      @glossary_admin_url = nil
      @glossary_extra     = []
      @enabled       = nil # tri-state: nil → derive from api_key
    end

    def enabled?
      return @enabled unless @enabled.nil?
      !api_key.to_s.strip.empty?
    end

    # True when the given request path is on the exclude list.
    # String entries are exact-match; Regexp entries use `===`.
    def excluded?(path)
      exclude_paths.any? { |p| p.is_a?(Regexp) ? p === path : p == path }
    end

    # One answer for "is this role an admin role", so the snippet's
    # inspector tag, the signed access level, and the render tracker
    # can never disagree — `admin_roles = [:admin]` used to enable
    # two of the three and silently leave the partial trail empty.
    def admin_role?(role)
      return false if role.nil?
      admin_roles.any? { |r| r.to_s == role.to_s }
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def production?
      if defined?(Rails) && Rails.respond_to?(:env)
        return Rails.env.production?
      end
      (ENV["RACK_ENV"] || ENV["RAILS_ENV"]).to_s == "production"
    rescue StandardError
      false
    end

    def configure
      yield configuration
    end

    # Handy for tests — restore defaults without process restart.
    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
