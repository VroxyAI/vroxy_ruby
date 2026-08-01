# frozen_string_literal: true

require "rails/railtie"

module Ctovibe
  # Rails glue.  Kept in its own file so `require "ctovibe"` from a
  # non-Rails context (say, a Sinatra app that only wants the
  # middleware) doesn't blow up trying to require rails/railtie.
  class Railtie < ::Rails::Railtie
    initializer "ctovibe.helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        helper Ctovibe::Helper
        # Auto-install the render tracker on every ApplicationController
        # descendant.  The `around_action` short-circuits on non-admin
        # identities, so non-admin request paths remain zero-cost.  If
        # a host app wants to keep the tracker out of a particular
        # controller subtree (e.g. an API mount), `skip_around_action
        # :ctovibe_track_rendered_partials` works — the method is named
        # deterministically for exactly this.
        include Ctovibe::AdminRenderTracker
      end
    end

    # Insert as late as possible so we see the FULLY rendered body,
    # including anything downstream middlewares (compression,
    # ETagging) would otherwise clobber.  Rack::ETag sits near the
    # top of the stack; putting us AFTER it means our body edits
    # invalidate the ETag it already computed — so we insert
    # BEFORE Rack::ETag to keep response headers coherent.
    initializer "ctovibe.middleware" do |app|
      app.middleware.insert_before Rack::ETag, Ctovibe::Middleware
    end
  end
end
