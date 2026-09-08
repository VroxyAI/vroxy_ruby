# vroxy

Drop-in Rails gem for the [vroxy](https://vroxy.ai) support widget.

Set your API key, and the widget snippet auto-injects on every HTML response — with the current user's email, name, and role forwarded to `vroxy.identify()` so support conversations land pre-identified.

## Install

The gem is **not published to RubyGems**, so point Bundler at the repo or a local checkout:

```ruby
# Gemfile
gem "vroxy", git: "git@github.com:VroxyAI/vroxy_ruby.git"
# or, working against a checkout:
gem "vroxy", path: "../vroxy_ruby"
```

```bash
bundle install
bin/rails generate vroxy:install
```

Then set your key (from your vroxy workspace → **Embed**):

```bash
# .env / your secret manager
VROXY_API_KEY=your_tenant_public_key
```

The public key is a 24-character alphanumeric string. It is not secret — it ships to the browser in the widget URL, which is exactly what the snippet does with it.

That's it. Every `text/html` response now carries the loader script + an `identify()` call for the current user.

A runnable example app lives in [`examples/rails-demo`](examples/rails-demo).

## What gets injected

Two `<script>` tags appended before `</body>` (a third for admins, see below):

```html
<script src="https://vroxy.ai/widget.js?tenant=YOUR_PUBLIC_KEY" async></script>
<script>
  (function(){
    window.vroxy = window.vroxy || function(){ (window.vroxy.q = window.vroxy.q || []).push(arguments); };
    window.vroxy("identify", {"email":"ada@example.com","name":"Ada Lovelace","external_id":"42","meta":{"role":"admin"},"role":"admin"});
  })();
</script>
```

The first script is the vroxy loader (served by vroxy.ai). The second identifies the logged-in user via the same public `vroxy(...)` API surface documented for hand-rolled installs — so migrating a customer between the two is a no-op on the widget side.

Every value inside those script bodies is escaped for script context (`<`, `>`, `&`, U+2028, U+2029 become `\uXXXX`), so a display name containing `</script>` cannot break out of the tag. The JSON still parses to the identical string.

## Identity resolution

By default the gem reads `controller.current_user` and pulls:

| Field         | Source                                                   |
| ------------- | -------------------------------------------------------- |
| `external_id` | `user.id.to_s`                                           |
| `email`       | `user.email`                                             |
| `name`        | `user.full_name` → `user.name` → `user.display_name` → `first_name + last_name` |
| `role`        | `user.role` → `user.roles.first`                         |

`email`, `name` and `external_id` are sent as top-level fields. `role` is sent BOTH as a top-level field and inside `meta` (deployments predating the top-level field still read it from `meta`). Every other key you return is folded into `meta`, vroxy's arbitrary-attributes escape hatch.

Missing accessors are quietly skipped, and blank values are dropped rather than sent as `""` — a bare `User(id, email)` still yields a useful identify payload.

### Custom resolver

Override for non-Devise auth, multi-tenant scoping, or when your role model doesn't match the default sniffing:

```ruby
Vroxy.configure do |config|
  config.identify = ->(controller) {
    user = controller.current_user
    next nil unless user

    {
      external_id: user.id.to_s,
      email:       user.email,
      name:        user.display_name,
      role:        user.admin? ? "admin" : "basic",
      meta:        {
        plan:      user.subscription&.plan_name,
        signup_at: user.created_at.iso8601
      }
    }
  }
end
```

Return `nil` to explicitly stay anonymous for a request (e.g. impersonation sessions where you don't want the impersonator's identity leaking to the widget).

The block runs inside the request render. If it raises, the gem logs a warning and serves the page **without** the widget — a support widget is never the reason a page 500s.

## Identity verification (access-gated bot tools)

vroxy bot tools have an access level: `public` (anyone), `user` (signed-in
visitors), or `admin`. To unlock the non-public tiers the widget has to prove
the visitor's level — an unsigned claim could be forged from the browser
console. Set the identity-verification secret from your vroxy workspace's
**Embed** page:

```ruby
Vroxy.configure do |config|
  config.identity_secret = ENV["VROXY_IDENTITY_SECRET"]
end
```

With the secret set, the snippet adds a `level` ("admin" when the resolved
`role` is in `config.admin_roles`, else "user") plus an HMAC-SHA256
`signature` over `external_id|email|level` to the identify payload. vroxy
recomputes the signature server-side; only a verified level unlocks gated
tools. An identify block can also return an explicit `level:` when your
notion of widget-admin isn't a single role string.

The secret stays server-side — only the derived signature reaches the page,
and it grants exactly that one identity's claims.

Two edge cases worth knowing:

- **A field containing `|` cannot be signed.** The canonical string is
  `external_id|email|level`, so `("a|b", "c")` and `("a", "b|c")` would
  produce the same digest. vroxy refuses such a claim, so the gem refuses to
  mint a signature that could never verify. `Identity.signature_for` raises
  `ArgumentError`; inside a page render that degrades to serving the page
  without the widget rather than raising.
- **If you hold the secret elsewhere**, return `level:` AND `signature:`
  from your identify block and leave `identity_secret` unset — the gem
  forwards the pair untouched.

## Admin UI-feedback inspector

When the resolved `role` is in `config.admin_roles` (default `%w[admin owner]`),
a third `<script type="module">` loads the inspector bundle from
`endpoint/admin_ui_inspector.js`. It lets an admin pick a DOM element,
screenshot the page, add a note, and file it against your vroxy workspace.

The gem hands it server-known context — the `controller#action` and the trail
of partials that rendered the page (`render_partial` and `render_collection`
alike), with your `Rails.root` prefix stripped. To keep the tracker out of a
controller subtree: `skip_around_action :vroxy_track_rendered_partials`.

## Exception reporting

The gem ships errors from your app to your vroxy workspace's **Errors**
page — no exception_notification or extra service needed. In production,
with `api_key` set, it's on automatically: the gem subscribes to Rails'
error reporter (`Rails.error`), so every unhandled request or job
exception is delivered (background thread, 3s timeouts, 60/min throttle —
reporting can never slow or break your app).

```ruby
Vroxy.configure do |config|
  config.report_errors = true                       # force on/off; nil = auto (production)
  config.error_ignore += %w[Some::ExpectedError]    # skip known non-bugs
end

# report a handled exception with context
rescue Stripe::CardError => e
  Vroxy.report_error(e, context: { order_id: order.id })
```

The widget reports its own JS errors from customer pages automatically,
and host pages can call `vroxy("reportError", err, { where: "checkout" })`.

## Safe queries (let the bot answer questions about YOUR data)

The vroxy bot can answer questions about a conversation. It cannot answer
"how many deals closed this week?", because `Deal` lives in **your**
database — which vroxy has no access to and should never have.

This gem is the only vroxy code running inside your app, so this is where
that gap closes. You declare a read-only allowlist; vroxy sends signed
queries to an endpoint the gem serves; the gem runs them against the models
you opted in and hands back rows plus the SQL that produced them.

Nothing is queryable until you say so. There is no "expose everything"
switch, and there is no way to reach a model, a column, or a row you did
not explicitly declare.

### 1. Declare what vroxy may read

```ruby
# config/initializers/vroxy.rb
Vroxy.configure do |config|
  config.api_key = ENV["VROXY_API_KEY"]

  config.safe_query.secret = ENV["VROXY_QUERY_SECRET"]

  config.safe_query.model "Deal",
    columns: %w[id account_id status amount currency closed_at created_at],
    scope:   ->(rel) { rel.where(archived: false) }

  config.safe_query.model "Account",
    columns: %w[id name plan created_at]
end
```

- **`columns:` is the whole world.** A column you leave out cannot be
  selected, filtered, grouped, ordered or aggregated on. `Deal#notes` above
  is not merely hidden from output — it cannot appear in a `where` either,
  so it can't be used to probe for values.
- **`scope:` runs first, on every query, and cannot be widened.** Caller
  steps are applied to the relation your lambda returned, and every step is
  a narrowing one (`where` / `where_not` / `order` / `limit` / `offset` /
  `group`). There is no `or`, no `unscope`, no `rewhere`. Use it for soft
  deletes, tenancy, drafts — anything that should never leave the building.
- **Credential-shaped column names are refused at boot.** Declaring
  `api_key`, `password_digest`, `session_token` or similar raises
  `Vroxy::SafeQuery::ConfigurationError` in your initializer rather than
  failing quietly at query time.

Generate a secret with `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`
and paste it into your vroxy workspace's settings. It must be at least 32
characters; a shorter one is refused.

### 2. That's it

The gem registers a Rack endpoint at **`/vroxy/query`**
(`config.safe_query.path` to move it). It stays a 404 passthrough until a
secret AND at least one model are configured, so installing the gem does
not open anything.

### Query grammar

vroxy sends JSON. This is the whole language:

```json
{
  "model": "Deal",
  "scope": [
    { "where": { "status": "won", "created_at_gte": "7.days.ago" } },
    { "order": "amount desc" },
    { "limit": 10 }
  ],
  "terminal": "pluck",
  "terminal_args": ["id", "amount"]
}
```

| Piece | Values |
| ----- | ------ |
| `scope` steps | `where`, `where_not`, `order`, `limit`, `offset`, `group` |
| terminals | `count`, `sum`, `average`, `minimum`, `maximum`, `pluck`, `first`, `last`, `to_a`, `exists?` |
| comparisons | `column_gt`, `column_gte`, `column_lt`, `column_lte` (in `where` only) |
| relative times | `"7.days.ago"`, `"1.hour.from_now"` — seconds through years |

Answers come back as `{"ok": true, "result": …, "sql": "SELECT …"}`, and a
refusal as `{"ok": false, "error": "…"}` explaining which rule it hit. The
SQL is returned so a human can audit exactly what ran.

A refusal is preferred to a wrong number. `sum` and `average` need a numeric
column — asking either of them for a string, boolean or timestamp column is
refused rather than answered, because SQLite happily returns `0.0` for
`SUM(status)` while PostgreSQL raises, and an invented aggregate is worse
than no aggregate. `minimum` and `maximum` still work on any column. Values
are checked against the column before the query runs: one that can't be cast
is refused ("it would match NULL and wrongly return nothing") and one too
wide for the column is refused as out of range, rather than quietly matching
nothing.

### What makes it read-only

- Every query runs inside a transaction that is **always rolled back**.
  Even a model callback or a `scope:` lambda that writes leaves nothing
  behind.
- There is no write terminal, and none can be reached: `delete_all`,
  `update_all`, `destroy_all` and `find_by_sql` are simply not in the
  grammar.
- **No caller string ever becomes SQL.** Column names are checked against
  your allowlist and then used as identifiers; values are bound. A column
  name like `id) OR 1=1 --` is refused, not escaped — the allowlist is a
  yes-list, not a sanitizer.
- Results are capped (50 rows by default, 200 max, tunable per model via
  `max_rows:`), including grouped aggregates. Plain `count` and `sum` are
  deliberately *not* capped, so totals stay true.

### Authentication

Every request carries three headers and is rejected without them:

| Header | Meaning |
| ------ | ------- |
| `X-Vroxy-Timestamp` | Unix seconds; must be within 5 minutes (`timestamp_tolerance`) |
| `X-Vroxy-Nonce` | 8–128 chars of `[A-Za-z0-9_.-]`, single-use |
| `X-Vroxy-Signature` | `v1=` + HMAC-SHA256, compared in constant time |

The signature covers `"vroxy:query:v1\n<timestamp>\n<nonce>\n<body>"` over
the exact request bytes, so a replayed, tampered, stale or unsigned request
is refused. Requests are also rate limited
(`max_requests_per_minute`, default 60) and bodies over 16 KB are rejected.

**`safe_query.secret` is deliberately a different secret from
`identity_secret`.** `identity_secret` signs public identity claims your app
makes *to* vroxy; this one lets vroxy read *from* your database. Different
direction, different blast radius, rotate independently — and sharing one
key across both directions of a protocol is how a signature minted for one
purpose gets replayed as the other.

### Verifying it yourself

Replay defence is in-process by default. **If you run more than one app
process**, point it at a shared store so a nonce burned on one worker is
burned on all of them:

```ruby
config.safe_query.nonce_store = Rails.cache   # Redis / Memcached
```

Outside `development` and `test`, the gem logs a single warning at boot when
safe queries are enabled and the nonce store is per-process. It cannot tell
you whether that is a problem: the number of Puma workers and the number of
replicas/dynos both live outside the process, so a single-worker app on four
containers looks identical from in here to a single-worker app on one. What
the warning does is say so, name the fix, and get sharper when it honestly
can — a `WEB_CONCURRENCY`/`PUMA_WORKERS` above 1 turns "this may bite you"
into "this is biting you", and a `nonce_store` that is itself per-process
(`MemoryStore`, `NullStore`) or per-host (`FileStore`) is named as such. It
warns; it never raises and never stops a boot.

If exactly one process serves the endpoint, say so and the warning stops:

```ruby
config.safe_query.single_process = true
```

That flag is an assertion you are making, not something the gem can verify,
and it does not silence the separate warning for `nonce_store = nil` — with
no store there is no replay defence even on one process.

To see the allowlist vroxy sees, POST a signed `{"describe": true}` — it
returns the models, the columns, and nothing else.

## Glossary sync

`bin/rails vroxy:sync_glossary` mines `activerecord.models` from your app's
i18n and teaches the bot your vocabulary — a model whose display label
differs from its key becomes an entry (`{ term: "product", aliases:
["Listing"] }`). Namespaced models and labels identical to the model name
are skipped. Needs `config.secret_token` (a tenant API token with
`tenant:read` + `tenant:write`), NOT the public `api_key`.

## Configuration reference

| Key             | Default                       | Purpose                                                                 |
| --------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `api_key`       | `ENV["VROXY_API_KEY"]`      | Tenant public key (24 chars).                                           |
| `endpoint`      | `ENV["VROXY_ENDPOINT"]` or `https://vroxy.ai` | Base URL of the vroxy deployment.                     |
| `enabled`       | `true` iff `api_key` present  | Master kill switch.                                                     |
| `auto_inject`   | `true`                        | Middleware appends the snippet before `</body>` on `text/html` responses. |
| `identify`      | *(auto-detect)*               | `->(controller) { {...} }`. Return `nil` to stay anonymous.             |
| `exclude_paths` | `[]`                          | Strings or Regexps matched against the request path; skipped by middleware. |
| `csp_nonce`     | `nil`                         | `->(controller) { controller.content_security_policy_nonce }` for strict CSP. Applied to every emitted tag, loader included. |
| `admin_roles`   | `%w[admin owner]`             | Roles that load the inspector and sign as `level: "admin"`. Strings or symbols. |
| `identity_secret` | `ENV["VROXY_IDENTITY_SECRET"]` | Workspace identity-verification secret; signs the identify payload's access level so gated bot tools unlock. |
| `report_errors` | `nil` (auto: production + api_key) | Ship unhandled exceptions to the workspace Errors page. |
| `error_ignore`  | RecordNotFound, RoutingError, … | Exception class names (incl. subclasses) never reported. |
| `secret_token`  | `ENV["VROXY_SECRET_TOKEN"]` | Tenant API token for `vroxy:sync_glossary`. Not the public key. |
| `glossary_admin_url` | `nil`                    | `->(model_key) { "https://app.example/admin/#{model_key}s/{id}" }`; `{id}` stays literal. |
| `glossary_extra` | `[]`                         | Entries appended verbatim to the i18n-derived ones. |

### Safe-query settings

All under `config.safe_query`.

| Key             | Default                       | Purpose                                                                 |
| --------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `secret`        | `ENV["VROXY_QUERY_SECRET"]`   | HMAC key for query requests. 32+ chars. Not `identity_secret`.          |
| `model(...)`    | *(none)*                      | Opt a model in: `columns:`, optional `scope:` and `max_rows:`.          |
| `path`          | `/vroxy/query`                | Where the endpoint is served.                                           |
| `enabled`       | `true` iff secret + a model   | Kill switch. Forcing `true` cannot open an unconfigured endpoint.       |
| `default_rows`  | `50`                          | Row limit when the caller doesn't set one.                              |
| `max_rows`      | `200`                         | Hard ceiling on rows returned (capped at 1000).                         |
| `timestamp_tolerance` | `300`                   | Seconds of clock skew allowed (max 900).                                |
| `max_requests_per_minute` | `60`                | Request cap; `0` closes the endpoint.                                   |
| `nonce_store`   | in-process                    | Set to `Rails.cache` for multi-process replay defence.                  |
| `single_process` | `false`                      | Assert that one process serves the endpoint; silences the boot warning above. |

## Manual placement (auto-inject off)

```ruby
Vroxy.configure { |c| c.auto_inject = false }
```

```erb
<%# app/views/layouts/application.html.erb, before </body> %>
<%= vroxy_snippet %>
```

Even with auto-inject on, calling `vroxy_snippet` in a layout suppresses the middleware for that request (no double injection).

## Middleware safety rules

The middleware is registered innermost, inside `Rack::ETag`, so the ETag digest covers the body *with* the snippet — two users' pages must never share a digest computed before their differing identify payloads were added.

It only rewrites a response when ALL of:

- Vroxy is enabled and `api_key` is set.
- `config.auto_inject` is true.
- The request path is not on `exclude_paths` (matched with and without a mounted app's `SCRIPT_NAME` prefix).
- `Content-Type` matches `text/html`.
- There is no `Content-Encoding` (a compressed body is bytes, not HTML).
- Status is 2xx (not 204, not redirect, not error).
- The body is valid text containing a literal `</body>`.
- The helper wasn't already used on this request.

Anything else is a passthrough — the original response bytes are untouched. Reading a body to inspect it consumes it, so once read, the buffered copy is what gets served on every path; a one-shot body is never handed back drained.

## Development

```bash
bundle install
bundle exec rake test
```

The suite runs on SQLite by default, with no service to start. The safe-query
tests also run against a real PostgreSQL, because that is where most host apps
live and the two adapters do not agree about everything:

```bash
docker run -d --name vroxy-pg-test -p 55432:5432 \
  -e POSTGRES_USER=vroxy_test -e POSTGRES_PASSWORD=vroxy_test \
  -e POSTGRES_DB=vroxy_gem_test postgres:16-alpine

VROXY_TEST_ADAPTER=postgresql bundle install
VROXY_TEST_ADAPTER=postgresql bundle exec rake test
```

`VROXY_TEST_DATABASE_URL` overrides the connection. `pg` is only installed
when `VROXY_TEST_ADAPTER` is set, so the default run stays dependency-free.
`test/safe_query_adapter_parity_test.rb` is the file that has to give the same
answer on both, and its first test fails loudly if the adapter switch didn't
take effect — a Postgres run that silently fell back to SQLite must not look
green.

## License

MIT.
