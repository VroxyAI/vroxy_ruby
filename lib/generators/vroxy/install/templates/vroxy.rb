# frozen_string_literal: true

# vroxy — support widget for Rails apps.
# See https://docs.vroxy.ai/libraries for the full guide.

Vroxy.configure do |config|
  # Your tenant public key, from your workspace's Embed page — a
  # 24-character alphanumeric string.  Safe to commit / expose: it
  # ships to the browser in the widget URL either way.  For staging
  # vs prod, prefer an env var.
  config.api_key  = ENV.fetch("VROXY_API_KEY", nil)

  # Override for self-hosted / staging deploys.
  # config.endpoint = "https://vroxy.ai"

  # Set to false to disable the widget everywhere without ripping
  # the initializer out (useful for e.g. incident response).
  # Defaults to true when api_key is present.
  # config.enabled = Rails.env.production?

  # When true (default), a Rack middleware appends the snippet
  # before </body> on every text/html response.  Set to false to
  # place `<%= vroxy_snippet %>` yourself in a layout.
  # config.auto_inject = true

  # Paths the middleware must NEVER touch.  Use for admin
  # dashboards, health-checks, or anything that shouldn't broadcast
  # who your logged-in user is to a support widget.
  # config.exclude_paths = ["/up", %r{\A/admin}]

  # Custom identity resolver.  Return a Hash — top-level keys
  # `email`, `name`, `external_id` map to vroxy's identify
  # endpoint; anything else lands under `meta` (arbitrary
  # customer-defined attributes).  Return `nil` to stay
  # anonymous for this request.
  #
  # Default (when this is unset) reads `controller.current_user`
  # and pulls `id / email / full_name || name / role`.
  #
  # config.identify = ->(controller) {
  #   user = controller.current_user
  #   next nil unless user
  #   {
  #     external_id: user.id.to_s,
  #     email:       user.email,
  #     name:        user.display_name,
  #     role:        user.admin? ? "admin" : "basic",
  #     meta:        { plan: user.subscription&.plan_name }
  #   }
  # }

  # Identity-verification secret from your vroxy workspace's
  # Embed page.  Lets the snippet SIGN the visitor's access level
  # ("user" / "admin") so access-gated bot tools unlock for them —
  # without it, identify still personalizes the chat but the
  # visitor stays at public tool access.  Keep it server-side.
  # config.identity_secret = ENV["VROXY_IDENTITY_SECRET"]

  # If the app runs a strict Content-Security-Policy that forbids
  # inline scripts, wire up the request nonce so the identify
  # <script> can carry it.
  # config.csp_nonce = ->(controller) { controller.content_security_policy_nonce }

  # Roles that trigger the admin UI-feedback inspector — a
  # floating 💡 launcher (bottom-left) that lets an admin pick a
  # DOM element, screenshot the page, add a note, and file it
  # against vroxy.  The note reaches your vroxy workspace, and
  # the assistant's reply comes back in the widget's chat panel
  # for that same visitor.
  #
  # Inspector bundle is loaded cross-origin from
  # `endpoint/admin_ui_inspector.js`; the customer app doesn't
  # ship a byte of picker code.
  # config.admin_roles = %w[admin owner]
end
