# frozen_string_literal: true

module Vroxy
  # Rendered by `<%= vroxy_snippet %>` in a layout.  Also marks the
  # request via a Rack env flag so the middleware skips auto-inject
  # (belt-and-suspenders: emitting the snippet twice would install
  # two visitor-token event loops, which the widget would recover
  # from but is wasteful).
  module Helper
    RENDERED_ENV_KEY = "vroxy.helper_rendered"

    def vroxy_snippet
      html = Vroxy::Snippet.render(self)
      request.env[RENDERED_ENV_KEY] = true if respond_to?(:request) && request
      html.respond_to?(:html_safe) ? html.html_safe : html
    end
  end
end
