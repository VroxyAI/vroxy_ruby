# frozen_string_literal: true

require "json"
require "cgi"

module Vroxy
  # Renders the HTML injected into customer pages.  Two-part output:
  #
  #   1. `<script src=".../widget.js?tenant=…" async>` —
  #      the loader served by Widget::BootController#show.  Async so
  #      it never blocks first paint; the boot script buffers any
  #      `window.vroxy(...)` calls into a queue until the real
  #      bundle takes over.
  #
  #   2. `<script>window.vroxy("identify", {...})</script>` — only
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

    # A `<` inside a JSON string value would otherwise close the
    # surrounding <script> element — a user whose display name is
    # `</script><img onerror=...>` would own every page of the host
    # app.  U+2028 / U+2029 are JS line terminators in engines
    # predating the ES2019 JSON superset.  The escaped forms decode
    # back to the same characters, so the JSON stays identical.
    SCRIPT_UNSAFE_CODEPOINTS = [ 0x3c, 0x3e, 0x26, 0x2028, 0x2029 ].freeze
    SCRIPT_ESCAPES = SCRIPT_UNSAFE_CODEPOINTS.to_h { |cp|
      [ cp.chr(Encoding::UTF_8), format("\\u%04x", cp) ]
    }.freeze
    SCRIPT_ESCAPE_RE = Regexp.union(SCRIPT_ESCAPES.keys).freeze

    # Renders the full snippet for a controller instance.  Returns
    # `""` when the gem is disabled or misconfigured — safe to
    # splat into a layout unconditionally.
    #
    # Output is 2–3 script tags:
    #
    #   1. Widget loader           (always, when enabled)
    #   2. vroxy.identify() call (when identity resolves to non-empty)
    #   3. Admin inspector loader  (when identity role ∈ config.admin_roles)
    #
    # A support widget must never be able to 500 a customer's page,
    # so in production a failure here degrades to no snippet.  In
    # every other environment it raises, because a silently missing
    # widget is a worse thing to ship than a loud test failure.
    def render(controller)
      config = Vroxy.configuration
      return "" unless config.enabled?
      return "" if config.api_key.to_s.strip.empty?

      identity = Identity.resolve(controller)
      loader   = loader_tag(config, controller)
      ident    = identify_tag(identity, config, controller)
      admin    = admin_inspector_tag(identity, config, controller)

      "#{loader}#{ident}#{admin}"
    rescue StandardError => e
      warn "[vroxy] snippet render failed, page served without the widget: #{e.class}: #{e.message}"
      ""
    end

    def script_json(value)
      JSON.generate(value).gsub(SCRIPT_ESCAPE_RE, SCRIPT_ESCAPES)
    end

    # The nonce belongs on the LOADER too, not just the inline
    # tags: under the nonce-only `script-src` this gem documents,
    # an un-nonced `<script src>` is blocked and the widget never
    # boots at all.
    def loader_tag(config, controller = nil)
      src        = "#{config.endpoint.chomp('/')}/widget.js?tenant=#{CGI.escape(config.api_key)}"
      nonce_attr = build_nonce_attr(config, controller)
      %(<script src="#{CGI.escapeHTML(src)}"#{nonce_attr} async></script>)
    end

    # The identify snippet piggy-backs on the queueing shim the
    # boot script installs at `window.vroxy`.  That shim is a
    # function that pushes arguments onto `vroxy.q`; the real
    # bundle replaces the function and drains the queue.  Either
    # ordering (loader before/after this tag) works — the queue
    # is the API contract.
    def identify_tag(identity, config, controller)
      return "" if identity.nil? || identity.empty?

      nonce_attr = build_nonce_attr(config, controller)
      payload    = script_json(identity_payload(identity, config))

      # `window.vroxy = window.vroxy || function(){ (window.vroxy.q = window.vroxy.q || []).push(arguments) }`
      # mirrors the shim in Widget::BootController#bootstrap_source_for.
      # We install it defensively BEFORE calling identify so the
      # host page's snippet works even if the loader is deferred /
      # blocked / late.
      body = <<~JS
        (function(){
          window.vroxy = window.vroxy || function(){ (window.vroxy.q = window.vroxy.q || []).push(arguments); };
          window.vroxy("identify", #{payload});
        })();
      JS

      %(<script#{nonce_attr}>#{body.strip}</script>)
    end

    # Split identity into the top-level fields the widget's
    # identify endpoint understands (email/name/external_id/role)
    # and push everything else — plan, tenant_id, whatever — into
    # `meta`, which is the vroxy endpoint's escape hatch for
    # arbitrary customer keys.  `role` ALSO stays in meta so
    # vroxy deployments predating the top-level field keep
    # seeing it where they always did.
    #
    # When `config.identity_secret` is set, the payload carries a
    # signed access `level` ("user"/"admin", see
    # Identity.level_for) — that's what unlocks access-gated bot
    # tools for this visitor.  No secret → no level/signature: an
    # unsigned claim would be spoofable from the console, so the
    # snippet doesn't emit one.  An identify block that computes
    # the pair itself (secret held elsewhere) is forwarded as-is —
    # dropping it would silently downgrade the visitor to public.
    def identity_payload(identity, config)
      top_keys = %i[email name external_id]
      top      = identity.slice(*top_keys)
      extra    = identity.except(*top_keys, :meta, :level, :signature)
      meta     = identity[:meta].is_a?(Hash) ? identity[:meta].dup : {}
      meta     = extra.merge(meta) # explicit :meta wins over sugar keys
      top[:meta] = meta unless meta.empty?
      top[:role] = identity[:role].to_s unless identity[:role].to_s.empty?

      secret = config.identity_secret.to_s
      if !secret.empty?
        level            = Identity.level_for(identity, config)
        top[:level]      = level
        top[:signature]  = Identity.signature_for(
          external_id: identity[:external_id], email: identity[:email],
          level: level, secret: secret
        )
      elsif !identity[:level].to_s.empty? && !identity[:signature].to_s.empty?
        top[:level]     = identity[:level].to_s
        top[:signature] = identity[:signature].to_s
      end

      top
    end

    # Emitted only when the identified user's `role` is in
    # `config.admin_roles`.  Dynamic-imports the inspector bundle
    # from `endpoint/admin_ui_inspector.js` (a stable public URL
    # served by vroxy.ai) and calls
    # `window.VroxyInspector.init(...)` with server-known
    # context so the picker has partial + controller/action data
    # without any DOM meta-tag scraping.
    #
    # Uses a `<script type="module">` because the esbuild output
    # on vroxy.ai is ESM; classic script tags can't load it.
    # `import()` returns a Promise so we chain `.then()` to fire
    # init once the module has finished evaluating (which is when
    # `VroxyInspector` is guaranteed to be on `window`).
    def admin_inspector_tag(identity, config, controller)
      return "" if identity.nil?
      role = identity[:role] || identity.dig(:meta, :role) || identity.dig(:meta, "role")
      return "" if role.nil?
      return "" unless config.admin_role?(role)

      init_args  = script_json(inspector_init_args(config, controller))
      script_url = script_json(("#{config.endpoint.chomp('/')}/admin_ui_inspector.js"))
      nonce_attr = build_nonce_attr(config, controller)

      body = <<~JS
        import(#{script_url})
          .then(function () {
            if (window.VroxyInspector && window.VroxyInspector.init) {
              window.VroxyInspector.init(#{init_args});
            }
          })
          .catch(function (e) { try { console.warn("[vroxy] inspector load failed:", e); } catch (_) {} });
      JS

      %(<script type="module"#{nonce_attr}>#{body.strip}</script>)
    end

    # Args passed to `VroxyInspector.init()`.  Only server-known
    # values — visitor_token is read client-side from the widget's
    # localStorage.  Partial trail comes from AdminRenderTracker's
    # `@_vroxy_rendered_partials` stash on the controller.
    def inspector_init_args(config, controller)
      partials =
        if controller && controller.instance_variable_defined?(:@_vroxy_rendered_partials)
          controller.instance_variable_get(:@_vroxy_rendered_partials) || []
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
