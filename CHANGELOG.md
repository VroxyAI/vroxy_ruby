# Changelog

## Unreleased

- **The Rails demo now checks the identity matrix** instead of listing
  it in the README and trusting the reader. `matrix_test.rb` drives
  the app through Rack::Test and asserts against rendered HTML: an
  anonymous visitor is never identified, a member signs at `user`, an
  admin at `admin`, the signature is a real HMAC of
  `external_id|email|level`, the secret never appears in a page, and an
  excluded path carries no snippet. The Express and Django demos
  already did this; Rails was the odd one out.

- **CI.** GitHub Actions runs `bundle exec rake test` on Ruby 3.1 (the
  gemspec's floor) and 3.4 on every push and PR. There was none before.

## 0.9.1 — 2026-09-07

The two things 0.9.0 shipped as unverified: the replay window nobody was told
about, and a query grammar that had only ever met SQLite.

### Added

- **A boot warning when replay defence is per-process.** Outside `development`
  and `test`, an app with safe queries enabled and an in-process nonce store
  now gets one warning through `Rails.logger` at boot. It warns; it never
  raises and never blocks a boot.

  It also admits what it can't know. "Is one process serving this?" is not
  answerable from inside the process — Puma's worker count and the
  replica/dyno count both live outside it, so a single-worker app on four
  containers is indistinguishable from a single-worker app on one, and the
  gem refuses to imply otherwise. Where evidence exists it uses it:
  `WEB_CONCURRENCY` / `PUMA_WORKERS` above 1 turns "this may bite you" into
  "this is biting you", and a store that is itself per-process
  (`MemoryStore`, `NullStore`) or per-host (`FileStore`) is named as such
  rather than counted as a fix.
- **`config.safe_query.single_process = true`** — the intent the machine
  can't detect, given somewhere to live. It silences the warning and is
  explicitly an assertion the operator is making. It does NOT silence
  `nonce_store = nil`, which is no replay defence on any number of processes.

### Fixed

Found by running the query grammar against a real PostgreSQL for the first
time. All three made the two adapters answer the same question differently:

- **`sum` / `average` on a non-numeric column are refused, not answered.**
  PostgreSQL raises on `SUM(status)`; SQLite returns `0.0`. An invented
  aggregate handed to a language model is worse than a refusal, so both now
  refuse, naming the column and its type. `minimum` / `maximum` still work on
  any column.
- **A NUL byte in a query value is refused with a plain message.** PostgreSQL
  raised a raw `ArgumentError: string contains null byte` from the driver;
  SQLite ran the query. Neither is an answer, and no text column can hold
  one, so it's now refused up front on every adapter.
- **A value too wide for its column says so.** An out-of-range integer was
  reported as "it would match NULL and wrongly return nothing", which is the
  wrong reason: the value is out of the column's range, and the message now
  says that. This is the difference an operator sees on a `t.integer` column,
  which is 4 bytes on PostgreSQL and 8 on SQLite.

### Testing

- **The safe-query suite runs on PostgreSQL as well as SQLite.**
  `VROXY_TEST_ADAPTER=postgresql` (plus optional `VROXY_TEST_DATABASE_URL`)
  switches the harness; SQLite stays the default so a normal run needs no
  service and installs no `pg`. `test/safe_query_adapter_parity_test.rb` is
  the file both adapters must answer identically, and its first test fails
  loudly if the switch didn't take — a Postgres run that quietly fell back to
  SQLite must not be able to look green.

## 0.9.0 — 2026-09-07

Safe queries: a read-only, allowlisted way for the vroxy bot to answer
questions about the host app's OWN data.

The bot could already answer questions about a conversation. It could not
answer "how many deals closed this week?", because that model lives in the
customer's database, which vroxy has no access to and must never have. This
gem is the only vroxy code running inside the host app, so this is where
that closes.

### Added

- **`config.safe_query.model "Deal", columns: [...], scope: ->(rel) { ... }`**
  — opt-in allowlist. A model that isn't declared is not queryable, and an
  undeclared column can never be selected, filtered, grouped or ordered on
  (so it can't be probed for values either). The `scope:` lambda runs before
  any caller step and cannot be widened: every step in the grammar narrows.
- **An HMAC-authenticated endpoint** at `/vroxy/query`
  (`config.safe_query.path`), registered as Rack middleware. It is a 404
  passthrough until a secret AND a model are configured, so installing the
  gem opens nothing. `{"describe": true}` returns the allowlist.
- **The same query grammar the vroxy server uses**, so there is one shape to
  learn and one to attack: `where` / `where_not` / `order` / `limit` /
  `offset` / `group`; `count` / `sum` / `average` / `minimum` / `maximum` /
  `pluck` / `first` / `last` / `to_a` / `exists?`; `_gt` / `_gte` / `_lt` /
  `_lte` suffixes; relative times like `"7.days.ago"`. Answers carry the
  result AND the SQL that ran, so a human can audit it.
- **Golden vectors** (`test/vectors/`) covering the grammar and the HMAC,
  in the same spirit as the identity-signing vectors — the fixture,
  allowlist and expected outcomes all live in the JSON, so a port to another
  host language can be checked against the same file instead of drifting.

### Security properties

- **Genuinely read-only.** Every query runs in a transaction that is always
  rolled back, so even a model callback or a `scope:` lambda that writes
  leaves nothing behind. No write terminal exists or can be reached.
- **No caller string ever becomes SQL.** Column names are checked against
  the allowlist and used as identifiers; values are bound. A column name
  like `id) OR 1=1 --` is refused, not escaped — the allowlist is a
  yes-list, not a sanitizer.
- **A separate secret from `identity_secret`.** That one signs public
  identity claims the app makes TO vroxy; this one lets vroxy read FROM the
  database. Different direction, different blast radius, rotated
  independently — and reusing one key across both directions of a protocol
  is how a signature minted for one purpose gets replayed as the other. The
  canonical string is domain-separated (`vroxy:query:v1`) so even an
  accidental reuse cannot cross-validate.
- **Replay, tamper and staleness are all refused**: single-use nonce,
  ±5 minute timestamp window, constant-time comparison over the exact
  request bytes. Malformed nonces and stale timestamps are rejected before
  the nonce store is touched, so an unauthenticated flood can't fill it.
- **Credential-shaped column names are refused at boot**, in the
  initializer where the integrator can see it, rather than quietly at query
  time.
- Bounded cost: row caps (including on grouped aggregates), a 16 KB body
  limit, a step-count cap, and a per-minute request limit.

### Note for multi-process deployments

Replay defence is in-process by default. Set
`config.safe_query.nonce_store = Rails.cache` (Redis/Memcached) so a nonce
burned on one worker is burned on all of them.

## 0.8.0 — 2026-09-07

Security and robustness pass over the whole library. The headline is a
cross-site scripting hole in the injected snippet; the rest is the gem
learning to never be the reason a host app breaks.

### Security

- **XSS: script-context escaping for every injected value.** The identify
  payload and the inspector's init args were serialized with plain
  `JSON.generate` and dropped into an inline `<script>`. JSON does not
  escape `<`, so a display name (or ANY `meta` value — those routinely
  carry org and request data) containing `</script>` closed the element
  early and injected arbitrary HTML onto the customer's page. `<`, `>`,
  `&`, U+2028 and U+2029 are now emitted as `\uXXXX`. The JSON still
  parses to the identical string and signatures are computed on
  pre-serialization values, so payload semantics and HMACs are unchanged —
  only the bytes in the HTML.
- **The CSP nonce is applied to the loader tag, not just the inline ones.**
  Under the nonce-only `script-src` this gem documents, an un-nonced
  `<script src>` is blocked outright, so the widget never booted at all
  for anyone running strict CSP.

### Never break the host app

- **A snippet render failure serves the page without the widget.** An
  identify block that raises, or an identity that cannot be signed, used
  to propagate straight out of the Rack middleware as an HTTP 500 — on
  every page, for that user. `|` is legal RFC 5322 atext, so
  `a|b@example.com` is a real address that could 500 a real customer.
  Matches the Node and Python SDKs. `Identity.signature_for` still raises
  for direct callers.
- **Registering the middleware can no longer crash boot.** The railtie
  asked for `insert_after Rack::ETag`. `MiddlewareStackProxy` only RECORDS
  that operation and validates it later, so an app that had run
  `config.middleware.delete Rack::ETag` died at boot with "No such
  middleware to insert after" — far outside the `rescue` that was meant to
  handle it, making the fallback dead code. Now registered with `use`,
  which lands innermost and therefore still inside `Rack::ETag`.
- **A one-shot response body is never handed back drained.** Reading a body
  to look for `</body>` consumes it; every bail-out path returned the
  ORIGINAL body object, so any body not backed by an Array (a file
  iterator, an Enumerator) served a blank page. The buffered copy is now
  what gets served on every path.
- **Compressed responses are left alone.** A gzipped body with
  `Content-Type: text/html` was scanned as text; on Ruby that raises
  `ArgumentError: invalid byte sequence in UTF-8` out of the middleware —
  another 500. Responses carrying a `Content-Encoding` are now skipped, and
  body scanning is encoding-safe regardless.

### Correctness

- **`admin_roles` accepts symbols.** Three places asked "is this an admin
  role" and one compared differently, so `admin_roles = [:admin]` loaded
  the inspector and signed `level: "admin"` while the render tracker stayed
  off — an inspector with a permanently empty partial trail. All three now
  call `Configuration#admin_role?`.
- **The render tracker sees collection renders.** It subscribed to
  `render_partial.action_view` only, but `render partial:, collection:`
  emits `render_collection.action_view` — and a row partial rendered that
  way is the likeliest thing an admin picks in the inspector.
- **A host-computed `level` + `signature` pair is forwarded.** Apps holding
  the secret elsewhere had `level` dropped silently and `signature` filed
  into `meta`, so the visitor arrived unverified with nothing to show for
  it.
- **`exclude_paths` matches the browser-visible path.** An engine mounted at
  `/admin` has that prefix in `SCRIPT_NAME`, not `PATH_INFO`, so excluding
  `%r{\A/admin}` silently did nothing.
- **Blank auto-inferred fields are dropped.** A user row with an empty email
  shipped `"email":""` and identified the visitor as someone with no
  address. The identify-block path was already normalized; auto-detect was
  not.
- **The glossary no longer mistakes a namespace for plural forms.**
  `activerecord.models.admin.user` was read as plural labels for a term
  named `admin`, publishing vocabulary the app never had. Terms the server
  would reject are dropped locally too, so one bad model can't 422 the
  whole sync.
- **`Vroxy.production?`** replaces a Rails-only environment check, so
  `report_errors` auto-mode works in a non-Rails production process.
- `AdminRenderTracker` no longer depends on an ActiveSupport core extension
  it never required, and tolerates `Rails.root` being unavailable.

### Added

- **`examples/rails-demo`** — a runnable Rails app showing install,
  configuration, signed identify, admin-gated inspector, and
  `exclude_paths`. Verified booting under `rackup`. See its README for what
  is and isn't exercised.
- 51 new tests (60 → 111). Every fix above has one, and each was proved to
  fail when the fix is reverted.

### Docs

- README: install instructions no longer point at RubyGems (the gem is
  private and unpublished), the sample payload matches what the code
  actually emits, and `admin_roles` / `secret_token` / `glossary_*` are
  documented.
- The generated initializer no longer claims public keys start with `pk_`.


## 0.7.0 — 2026-09-06

- **Refuse to sign an identity claim whose fields contain `|`.** The
  signed string is `external_id|email|level`, so a field holding the
  separator makes it ambiguous — `("a|b", "c")` and `("a", "b|c")`
  sign identically, and one identity's signature would verify the
  other. Vroxy now rejects such claims, so signing one produced a
  signature that could never verify. `signature_for` raises
  `ArgumentError` instead, where an integrator can see it.

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


## 0.2.0

- **Admin inspector loader.** When the identify block returns a
  `role` in `config.admin_roles` (default `%w[admin owner]`), the
  snippet emits a third `<script type="module">` that dynamic-
  imports `endpoint/admin_ui_inspector.js` from ctovibe.ai and
  calls `CtovibeInspector.init({tenant, endpoint,
  controller_action, rendered_partials})`. Turns any Rails app
  running the gem into a surface where admins can pick an
  element, add a note, and send it to ctovibe's coding agent
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
