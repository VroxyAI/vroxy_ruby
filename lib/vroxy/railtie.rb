# frozen_string_literal: true

require "rails/railtie"

module Vroxy
  # Rails glue.  Kept in its own file so `require "vroxy"` from a
  # non-Rails context (say, a Sinatra app that only wants the
  # middleware) doesn't blow up trying to require rails/railtie.
  class Railtie < ::Rails::Railtie
    initializer "vroxy.helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        helper Vroxy::Helper
        # Auto-install the render tracker on every ApplicationController
        # descendant.  The `around_action` short-circuits on non-admin
        # identities, so non-admin request paths remain zero-cost.  If
        # a host app wants to keep the tracker out of a particular
        # controller subtree (e.g. an API mount), `skip_around_action
        # :vroxy_track_rendered_partials` works — the method is named
        # deterministically for exactly this.
        include Vroxy::AdminRenderTracker
      end
    end

    rake_tasks do
      load File.expand_path("../tasks/vroxy.rake", __dir__)
    end

    # The injector must sit INSIDE Rack::ETag so the digest covers
    # the body WITH the snippet — outside it, two users' pages
    # (different identify() payloads) share one ETag and a
    # conditional GET can serve user A's identify block to user B.
    # `use` appends to the very end of the stack, which is inside
    # every default middleware including Rack::ETag.  An explicit
    # `insert_after Rack::ETag` would look more precise and is a
    # trap: MiddlewareStackProxy only records the operation, so an
    # app that ran `config.middleware.delete Rack::ETag` fails at
    # boot with "No such middleware", far away from any rescue
    # this file could write.
    initializer "vroxy.middleware" do |app|
      app.middleware.use Vroxy::Middleware
    end

    initializer "vroxy.safe_query" do |app|
      app.middleware.use Vroxy::SafeQuery::Middleware
    end

    # Subscribe AFTER the host's initializers ran (that's where
    # api_key / report_errors get set).  `Rails.error.subscribe`
    # hands the subscriber every unhandled request/job exception —
    # no rescue middleware, no exception_notification dependency.
    config.after_initialize do
      if defined?(Rails.error) && Vroxy.configuration.report_errors?
        Rails.error.subscribe(Vroxy::ErrorSubscriber.new)
      end
    end
  end
end
