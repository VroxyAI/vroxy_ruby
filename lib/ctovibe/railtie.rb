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
    # invalidate the ETag it already computed.
    #
    # CORRECTION: the injector must sit INSIDE Rack::ETag
    # (insert_after = closer to the app) so the digest covers the
    # body WITH the snippet — insert_before left two users' pages
    # (different identify() payloads) sharing one ETag, and a
    # conditional GET could serve user A's cached identify block
    # to user B.  Host apps without Rack::ETag get a plain append.
    rake_tasks do
      load File.expand_path("../tasks/ctovibe.rake", __dir__)
    end

    initializer "ctovibe.middleware" do |app|
      begin
        app.middleware.insert_after Rack::ETag, Ctovibe::Middleware
      rescue StandardError
        app.middleware.use Ctovibe::Middleware
      end
    end

    # Subscribe AFTER the host's initializers ran (that's where
    # api_key / report_errors get set).  `Rails.error.subscribe`
    # hands the subscriber every unhandled request/job exception —
    # no rescue middleware, no exception_notification dependency.
    config.after_initialize do
      if defined?(Rails.error) && Ctovibe.configuration.report_errors?
        Rails.error.subscribe(Ctovibe::ErrorSubscriber.new)
      end
    end
  end
end
