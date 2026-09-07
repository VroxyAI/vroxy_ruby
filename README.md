# vroxy

Drop-in Rails gem for the [vroxy](https://vroxy.ai) support widget.

Set your API key, and the widget snippet auto-injects on every HTML response — with the current user's email, name, and role forwarded to `vroxy.identify()` so support conversations land pre-identified.

## Install

The gem is **not published to RubyGems** (pre-launch, private), so point Bundler at the repo or a local checkout:

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

## License

MIT.
