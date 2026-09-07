# frozen_string_literal: true

# `ActiveSupport::Concern` + `ActiveSupport::Notifications` are
# both provided by activesupport, which railties (our declared
# runtime dep) pulls in transitively.  Requiring them explicitly
# lets the gem's isolated test suite run without booting Rails.
require "active_support/concern"
require "active_support/isolated_execution_state"
require "active_support/notifications"

module Vroxy
  # Per-request capture of every `render_partial.action_view`
  # notification a controller emits, so the vroxy admin
  # inspector (loaded cross-origin from vroxy.ai when
  # identify says role=admin) can attach "this element came from
  # `app/views/posts/_row.html.erb`" to a UI-feedback note.
  #
  # Auto-included in `ActionController::Base` by the Railtie —
  # host apps get this for free.  The `around_action` is a no-op
  # unless the current user's identify payload puts them in
  # `config.admin_roles`, so non-admin request paths pay zero
  # cost.
  #
  # The captured trail is stashed on the controller as
  # `@_vroxy_rendered_partials` (array of `{path:, ms:}`) and
  # picked up by `Vroxy::Snippet` at render time — it goes into
  # the loader's `init()` call rather than a separate meta tag,
  # so the inspector has the trail immediately without any DOM
  # scraping.
  module AdminRenderTracker
    extend ActiveSupport::Concern

    # Runaway guard for pages that render huge collections (a
    # `render collection: [...5000...]` would otherwise flood the
    # array + downstream JSON serialization).
    MAX_PARTIALS = 200

    # `render partial:, collection:` emits render_collection, not
    # render_partial — and a row partial in a collection is the
    # single most likely thing an admin picks in the inspector.
    RENDER_EVENTS = /\Arender_(partial|collection)\.action_view\z/

    included do
      around_action :vroxy_track_rendered_partials,
                    if: :vroxy_admin_render_tracking_enabled?
    end

    private

    def vroxy_admin_render_tracking_enabled?
      identity = Vroxy::Identity.resolve(self)
      return false if identity.nil? || identity.empty?
      role = identity[:role] || identity.dig(:meta, :role) || identity.dig(:meta, "role")
      Vroxy.configuration.admin_role?(role)
    rescue StandardError
      # Any failure to resolve the identity (broken current_user,
      # exception in the configured block) should silently disable
      # tracking rather than take out the request.
      false
    end

    def vroxy_track_rendered_partials
      @_vroxy_rendered_partials = []

      partial_sub = ->(_name, start, finish, _id, payload) {
        # `break` inside a Proc raises LocalJumpError on some
        # Ruby patches — skip the append instead of trying to
        # short-circuit the enumeration.
        next if @_vroxy_rendered_partials.length >= MAX_PARTIALS
        identifier = payload[:identifier].to_s
        next if identifier.empty?
        @_vroxy_rendered_partials << {
          path: shorten(identifier),
          ms:   ((finish - start) * 1000).round(1)
        }
      }

      ActiveSupport::Notifications.subscribed(partial_sub, RENDER_EVENTS) do
        yield
      end
    end

    # Strip the Rails root prefix so the emitted payload doesn't
    # leak the container's absolute path.  Anything outside the
    # app tree (gems, engines) keeps its full path — that's still
    # useful signal for whoever reads the feedback, not a leak.
    def shorten(identifier)
      root = (Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root)).to_s
      return identifier if root.empty?
      identifier.start_with?(root) ? identifier.sub("#{root}/", "") : identifier
    end
  end
end
