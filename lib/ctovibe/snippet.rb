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
    #
    # Output is 2–3 script tags:
    #
    #   1. Widget loader           (always, when enabled)
    #   2. ctovibe.identify() call (when identity resolves to non-empty)
    #   3. Admin inspector loader  (when identity role ∈ config.admin_roles)
    def render(controller)
      config = Ctovibe.configuration
      return "" unless config.enabled?
      return "" if config.api_key.to_s.strip.empty?

      identity = Identity.resolve(controller)
      loader   = loader_tag(config)
      ident    = identify_tag(identity, config, controller)
      admin    = admin_inspector_tag(identity, config, controller)

      "#{loader}#{ident}#{admin}"
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
      payload    = JSON.generate(identity_payload(identity, config))

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
    # identify endpoint understands (email/name/external_id/role)
    # and push everything else — plan, tenant_id, whatever — into
    # `meta`, which is the ctovibe endpoint's escape hatch for
    # arbitrary customer keys.  `role` ALSO stays in meta so
    # ctovibe deployments predating the top-level field keep
    # seeing it where they always did.
    #
    # When `config.identity_secret` is set, the payload carries a
    # signed access `level` ("user"/"admin", see
    # Identity.level_for) — that's what unlocks access-gated bot
    # tools for this visitor.  No secret → no level/signature: an
    # unsigned claim would be spoofable from the console, so the
    # snippet doesn't emit one.
    def identity_payload(identity, config)
      top_keys = %i[email name external_id]
      top      = identity.slice(*top_keys)
      extra    = identity.except(*top_keys, :meta, :level)
      meta     = identity[:meta].is_a?(Hash) ? identity[:meta].dup : {}
      meta     = extra.merge(meta) # explicit :meta wins over sugar keys
      top[:meta] = meta unless meta.empty?
      top[:role] = identity[:role].to_s unless identity[:role].to_s.empty?

      secret = config.identity_secret.to_s
      unless secret.empty?
        level            = Identity.level_for(identity, config)
        top[:level]      = level
        top[:signature]  = Identity.signature_for(
          external_id: identity[:external_id], email: identity[:email],
          level: level, secret: secret
        )
      end

      top
    end

    # Emitted only when the identified user's `role` is in
    # `config.admin_roles`.  Dynamic-imports the inspector bundle
    # from `endpoint/admin_ui_inspector.js` (a stable public URL
    # served by ctovibe.ai) and calls
    # `window.CtovibeInspector.init(...)` with server-known
    # context so the picker has partial + controller/action data
    # without any DOM meta-tag scraping.
    #
    # Uses a `<script type="module">` because the esbuild output
    # on ctovibe.ai is ESM; classic script tags can't load it.
    # `import()` returns a Promise so we chain `.then()` to fire
    # init once the module has finished evaluating (which is when
    # `CtovibeInspector` is guaranteed to be on `window`).
    def admin_inspector_tag(identity, config, controller)
      return "" if identity.nil?
      role = identity[:role] || identity.dig(:meta, :role) || identity.dig(:meta, "role")
      return "" if role.nil?
      return "" unless config.admin_roles.map(&:to_s).include?(role.to_s)

      init_args  = JSON.generate(inspector_init_args(config, controller))
      script_url = "#{config.endpoint.chomp('/')}/admin_ui_inspector.js"
      nonce_attr = build_nonce_attr(config, controller)

      body = <<~JS
        import(#{script_url.to_json})
          .then(function () {
            if (window.CtovibeInspector && window.CtovibeInspector.init) {
              window.CtovibeInspector.init(#{init_args});
            }
          })
          .catch(function (e) { try { console.warn("[ctovibe] inspector load failed:", e); } catch (_) {} });
      JS

      %(<script type="module"#{nonce_attr}>#{body.strip}</script>)
    end

    # Args passed to `CtovibeInspector.init()`.  Only server-known
    # values — visitor_token is read client-side from the widget's
    # localStorage.  Partial trail comes from AdminRenderTracker's
    # `@_ctovibe_rendered_partials` stash on the controller.
    def inspector_init_args(config, controller)
      partials =
        if controller && controller.instance_variable_defined?(:@_ctovibe_rendered_partials)
          controller.instance_variable_get(:@_ctovibe_rendered_partials) || []
        else
          []
        end

      controller_action =
        if controller && controller.respond_to?(:controller_path) && controller.respond_to?(:action_name)
          "#{controller.controller_path}##{controller.action_name}"
        else
          ""
        end

      {
        tenant:            config.api_key,
        endpoint:          config.endpoint,
        controller_action: controller_action,
        rendered_partials: partials
      }
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
