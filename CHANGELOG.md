## 0.6.1 — 2026-08-30

- Dropped the redundant `data-tenant` attribute from the loader tag. The tenant key already rides in the script `src` query string, which is the only place the widget reads it; nothing consumed the attribute. Snippets already deployed on customer pages keep working — the attribute is simply ignored.

## 0.6.0 — 2026-08-24

- **BREAKING: the gem is now `vroxy`** (formerly `ctovibe`) — clean break, no shims. `require "vroxy"`, `module Vroxy`, initializer `config/initializers/vroxy.rb`, generator `ctovibe:install` → `vroxy:install`, rake task file `lib/tasks/vroxy.rake`, manual API `Vroxy.report_error`.
- Env vars renamed: `CTOVIBE_*` → `VROXY_*` (`VROXY_API_KEY`, `VROXY_ENDPOINT`, `VROXY_IDENTITY_SECRET`, `VROXY_SECRET_TOKEN`, ...). Default endpoint is now `https://vroxy.ai`.
- Wire/JS surface renamed to match the vroxy backend: `window.vroxy(...)` global, `VroxyInspector`, error ingest and glossary sync now target vroxy.ai.
- Gemspec: name `vroxy`, homepage `https://vroxy.ai`, contact `hello@vroxy.ai`.

## 0.5.0 — 2026-08-24

- **Built-in exception reporting** — no exception_notification dependency. `Rails.error.subscribe` (Rails 7+) hands the gem every unhandled request/job exception plus anything the app reports via `Rails.error.report`; each becomes a POST to ctovibe's `/ingest/errors` (public-key authed) and lands on the workspace's Errors page. Manual API: `Ctovibe.report_error(exception, context: {...})`.
- New config: `report_errors` (tri-state — nil auto-enables in production when `api_key` is set; true/false force, but no key or blank endpoint always disables) and `error_ignore` (class-name list matched against ancestors; defaults cover RecordNotFound / RoutingError / CSRF and similar non-bugs).
- Delivery can never hurt the host app: background thread, 3s timeouts, in-process 60/min throttle, every failure swallowed. `ErrorReporter.transport` is injectable for tests.

## 0.4.0 — 2026-08-23

- **Signed identity levels (access-gated bot tools).** New config `identity_secret` (ENV `CTOVIBE_IDENTITY_SECRET`, from the workspace Embed page). When set, the identify payload carries `level` ("admin" when the resolved role is in `admin_roles`, else "user"; an identify block may return an explicit `level:`) plus an HMAC-SHA256 `signature` over `external_id|email|level`. ctovibe verifies the signature and only a VERIFIED level unlocks `user`/`admin` bot tools — an unsigned claim would be forgeable from the console, so without the secret the snippet emits neither field.
- `role` is now also a top-level identify field (still mirrored into `meta` for older ctovibe deployments).
- FIX (tests): `AdminRenderTrackerTest`'s teardown removed the real `Identity.resolve` (the stub replaces `module_function`'s singleton copy, so `remove_method` deleted it for every later test file — order-dependent). Teardown now restores the saved original.

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
