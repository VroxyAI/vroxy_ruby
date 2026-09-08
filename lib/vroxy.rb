# frozen_string_literal: true

require "vroxy/version"
require "vroxy/configuration"
require "vroxy/identity"
require "vroxy/admin_render_tracker"
require "vroxy/snippet"
require "vroxy/helper"
require "vroxy/middleware"
require "vroxy/glossary"
require "vroxy/error_reporter"
require "vroxy/safe_query"

# Railtie is optional — loading it only when Rails is present
# lets `require "vroxy"` succeed in a plain Rack / Sinatra app
# that just wants the middleware.
require "vroxy/railtie" if defined?(Rails::Railtie)
