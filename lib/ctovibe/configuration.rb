# frozen_string_literal: true

module Ctovibe
  # Singleton config populated once at boot (typically from
  # `config/initializers/ctovibe.rb`).  Kept intentionally small:
  # the widget itself is configured server-side on ctovibe.io — the
  # host-app config is just credentials + integration knobs.
  class Configuration
    # `pk_…` tenant public key.  Same value the customer sees on
    # their ctovibe workspace settings page; safe to ship to the
    # browser (that's literally what happens — the widget URL
    # carries it as a query param).  Required.
    attr_accessor :api_key

    # Base URL of the ctovibe deployment serving `/widget.js`.
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
    # false if the host app wants to place `<%= ctovibe_snippet %>`
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

    # Tenant-owned ctovibe API token (tenant:write) for
    # server-to-server calls — the glossary sync rake task.  NOT
    # the public api_key.  Reads ENV CTOVIBE_SECRET_TOKEN.
    attr_accessor :secret_token

    # Identity-verification secret from the ctovibe workspace's
    # Embed page.  When set, the snippet signs the identify
    # payload's access claims (external_id / email / level) with
    # HMAC-SHA256 — that's what lets ctovibe TRUST "this visitor
    # is a signed-in user / an admin" and unlock access-gated bot
    # tools for them.  Without it, identify still personalizes
    # the conversation but the visitor stays at public tool
    # access (an unsigned claim would let any visitor self-claim
    # admin from the console).  Server-side only — never ship it
    # to the browser yourself; the snippet only emits the derived
    # signature.  Reads ENV CTOVIBE_IDENTITY_SECRET.
    attr_accessor :identity_secret

    # Optional: build an admin deep-link template for a glossary
    # term.  `->(model_key) { "https://myapp.com/admin/#{model_key}s/{id}" }`
    # — return nil to skip.  Literal "{id}" stays in the template;
    # ctovibe fills it per record.
    attr_accessor :glossary_admin_url

    # Optional: extra glossary entries appended verbatim to the
    # i18n-derived ones — `[{ "term" => ..., "aliases" => [...] }]`.
    attr_accessor :glossary_extra

    def initialize
      @api_key       = ENV["CTOVIBE_API_KEY"]
      @endpoint      = ENV.fetch("CTOVIBE_ENDPOINT", "https://ctovibe.ai")
      @auto_inject   = true
      @identify      = nil
      @csp_nonce     = nil
      @exclude_paths = []
      @admin_roles   = %w[admin owner]
      @secret_token  = ENV["CTOVIBE_SECRET_TOKEN"]
      @identity_secret = ENV["CTOVIBE_IDENTITY_SECRET"]
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
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
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
