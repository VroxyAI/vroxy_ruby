## 0.3.0 — 2026-08-15

- `bin/rails ctovibe:sync_glossary` — mines `activerecord.models` i18n labels (where per-env/whitelabel nounage lives) into ctovibe glossary entries and PUTs them to `/api/v1/glossary`.
- FIX: middleware now inserts INSIDE Rack::ETag (digest covers the injected body — no more cross-user 304s) and tolerates stacks without Rack::ETag; Content-Length is updated under its original header case (Rack 3 plain-Hash responses no longer get a duplicate stale header).
- New config: `secret_token` (ENV `CTOVIBE_SECRET_TOKEN`, tenant:write API token), `glossary_admin_url` (proc building admin deep-link templates per model), `glossary_extra` (verbatim extra entries).

# Changelog

## 0.2.0

- **Admin inspector loader.** When the identify block returns a
  `role` in `config.admin_roles` (default `%w[admin owner]`), the
  snippet emits a third `<script type="module">` that dynamic-
  imports `endpoint/admin_ui_inspector.js` from ctovibe.ai and
  calls `CtovibeInspector.init({tenant, endpoint,
  controller_action, rendered_partials})`. Turns any Rails app
  running the gem into a surface where admins can pick an
  element, add a note, and send it to Claude via ctovibe_dispatch
  — without the host app writing a single line of JS or having
  ctovibe.ai-specific views.
- **`Ctovibe::AdminRenderTracker` concern.** Auto-installed on
  `ActionController::Base` via the Railtie. Captures every
  `render_partial.action_view` notification for admin-role
  requests only (non-admin requests pay zero cost). Trail is
  stashed on the controller as `@_ctovibe_rendered_partials` and
  passed to the inspector via the loader's `init()` args.
- **New config: `admin_roles`.** Role allowlist that triggers the
  inspector loader and the render tracker.
- Updated install-generator initializer template with an
  `admin_roles` example.

## 0.1.0

- Initial release.
- `Ctovibe.configure` DSL: `api_key`, `endpoint`, `enabled`, `auto_inject`, `identify` block.
- `ctovibe_snippet` view helper for explicit placement.
- Rack middleware that auto-injects the loader script + `ctovibe.identify()` call before `</body>` on HTML responses.
- Default identify inference from `current_user` (id / email / name / role).
- `rails generate ctovibe:install` writes `config/initializers/ctovibe.rb`.
