# frozen_string_literal: true

require "ctovibe/version"
require "ctovibe/configuration"
require "ctovibe/identity"
require "ctovibe/snippet"
require "ctovibe/helper"
require "ctovibe/middleware"

# Railtie is optional — loading it only when Rails is present
# lets `require "ctovibe"` succeed in a plain Rack / Sinatra app
# that just wants the middleware.
require "ctovibe/railtie" if defined?(Rails::Railtie)
