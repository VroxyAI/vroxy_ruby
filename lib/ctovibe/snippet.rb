# frozen_string_literal: true

require "json"
require "cgi"

module Ctovibe
  # Renders the HTML injected into customer pages.  Two-part output:
  #
  #   1. `<script src=".../widget.js?tenant=…" data-tenant="…" async>` —
  #      the loader served by Widget::BootController#show.  Async so
  #      it never blocks first paint; the boot script buffers any
  #      `window.ctovibe(...)` calls into a queue until the real
  #      bundle takes over.
  #
  #   2. `<script>window.ctovibe("identify", {...})</script>` — only
  #      emitted when Identity.resolve returned a non-empty hash.
  #      This is EXACTLY the API surface documented for customers,
  #      so gem-injected identify and hand-rolled JS behave the
  #      same (same server-side endpoint, same visitor merge).
  #
  # The output is a marked-safe HTML string; the middleware treats
  # it as a byte payload and the helper hands it to Rails as
  # `html_safe`.  All dynamic values pass through JSON.generate
  # (script-body values) or CGI.escapeHTML (attribute values).
  module Snippet
    module_function

    # Renders the full snippet for a controller instance.  Returns
    # `""` when the gem is disabled or misconfigured — safe to
    # splat into a layout unconditionally.
    def render(controller)
      config = Ctovibe.configuration
      return "" unless config.enabled?
      return "" if config.api_key.to_s.strip.empty?

      identity = Identity.resolve(controller)
      loader   = loader_tag(config)
      ident    = identify_tag(identity, config, controller)

      "#{loader}#{ident}"
    end

    def loader_tag(config)
      src    = "#{config.endpoint.chomp('/')}/widget.js?tenant=#{CGI.escape(config.api_key)}"
      tenant = CGI.escapeHTML(config.api_key)
      %(<script src="#{CGI.escapeHTML(src)}" data-tenant="#{tenant}" async></script>)
    end

    # The identify snippet piggy-backs on the queueing shim the
    # boot script installs at `window.ctovibe`.  That shim is a
    # function that pushes arguments onto `ctovibe.q`; the real
    # bundle replaces the function and drains the queue.  Either
    # ordering (loader before/after this tag) works — the queue
    # is the API contract.
    def identify_tag(identity, config, controller)
      return "" if identity.nil? || identity.empty?

      nonce_attr = build_nonce_attr(config, controller)
      payload    = JSON.generate(identity_payload(identity))

      # `window.ctovibe = window.ctovibe || function(){ (window.ctovibe.q = window.ctovibe.q || []).push(arguments) }`
      # mirrors the shim in Widget::BootController#bootstrap_source_for.
      # We install it defensively BEFORE calling identify so the
      # host page's snippet works even if the loader is deferred /
      # blocked / late.
      body = <<~JS
        (function(){
          window.ctovibe = window.ctovibe || function(){ (window.ctovibe.q = window.ctovibe.q || []).push(arguments); };
          window.ctovibe("identify", #{payload});
        })();
      JS

      %(<script#{nonce_attr}>#{body.strip}</script>)
    end

    # Split identity into the top-level fields the widget's
    # identify endpoint understands (email/name/external_id) and
    # push everything else — role, plan, tenant_id, whatever —
    # into `meta`, which is the ctovibe endpoint's escape hatch
    # for arbitrary customer keys.
    def identity_payload(identity)
      top_keys = %i[email name external_id]
      top      = identity.slice(*top_keys)
      extra    = identity.except(*top_keys, :meta)
      meta     = identity[:meta].is_a?(Hash) ? identity[:meta].dup : {}
      meta     = extra.merge(meta) # explicit :meta wins over sugar keys
      top[:meta] = meta unless meta.empty?
      top
    end

    def build_nonce_attr(config, controller)
      return "" unless config.csp_nonce
      nonce = config.csp_nonce.call(controller)
      return "" if nonce.to_s.empty?
      %( nonce="#{CGI.escapeHTML(nonce)}")
    rescue StandardError
      "" # never let a CSP lookup take down the render
    end
  end
end
