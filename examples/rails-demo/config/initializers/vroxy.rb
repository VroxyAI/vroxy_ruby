# frozen_string_literal: true

Vroxy.configure do |config|
  config.api_key  = ENV.fetch("VROXY_API_KEY", "demopublickey00000000000")
  config.endpoint = ENV.fetch("VROXY_ENDPOINT", "https://vroxy.ai")

  # Server-side only.  Without it the widget still personalizes the
  # conversation, but the visitor stays at PUBLIC tool access — an
  # unsigned "I'm an admin" claim is one console call away.
  config.identity_secret = ENV["VROXY_IDENTITY_SECRET"]

  config.identify = lambda do |controller|
    user = controller.current_user
    next nil unless user

    {
      external_id: user.id.to_s,
      email:       user.email,
      name:        user.name,
      role:        user.role,
      meta:        { plan: user.plan }
    }
  end

  config.admin_roles   = %w[admin owner]
  config.exclude_paths = [ "/up", %r{\A/rails/} ]

  # Ships unhandled exceptions to the workspace Errors page.  nil
  # (the default) would arm this in production only.
  config.report_errors = false
end
