# vroxy

Drop-in Rails gem for the [vroxy](https://vroxy.ai) support widget.

Set your API key, and the widget snippet auto-injects on every HTML response — with the current user's email, name, and role forwarded to `vroxy.identify()` so support conversations land pre-identified.

## Install

```ruby
# Gemfile
gem "vroxy"
```

```bash
bundle install
bin/rails generate vroxy:install
```

Then set your key (from https://vroxy.ai → workspace settings):

```bash
# .env / your secret manager
VROXY_API_KEY=pk_live_...
```

That's it. Every `text/html` response now carries the loader script + an `identify()` call for the current user.

## What gets injected

Two `<script>` tags appended before `</body>`:

```html
<script src="https://vroxy.ai/widget.js?tenant=pk_live_..." data-tenant="pk_live_..." async></script>
<script>
  (function(){
    window.vroxy = window.vroxy || function(){ (window.vroxy.q = window.vroxy.q || []).push(arguments); };
    window.vroxy("identify", {"email":"ada@example.com","name":"Ada Lovelace","external_id":"42","meta":{"role":"admin"}});
  })();
</script>
```

The first script is the vroxy loader (served by vroxy.ai). The second identifies the logged-in user via the same public `vroxy(...)` API surface documented for hand-rolled installs — so migrating a customer between the two is a no-op on the widget side.

## Identity resolution

By default the gem reads `controller.current_user` and pulls:

| Field         | Source                                                   |
| ------------- | -------------------------------------------------------- |
| `external_id` | `user.id.to_s`                                           |
| `email`       | `user.email`                                             |
| `name`        | `user.full_name` → `user.name` → `first_name + last_name` |
| `role`        | `user.role` → `user.roles.first`                         |

Everything except `email` / `name` / `external_id` is forwarded under `meta` (vroxy's arbitrary-attributes escape hatch), so `role: "admin"` becomes `meta: { role: "admin" }` on the wire.

Missing accessors are quietly skipped — a bare `User(id, email)` still yields a useful identify payload.

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

## Configuration reference

| Key             | Default                       | Purpose                                                                 |
| --------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `api_key`       | `ENV["VROXY_API_KEY"]`      | Tenant public key (`pk_...`).                                           |
| `endpoint`      | `ENV["VROXY_ENDPOINT"]` or `https://vroxy.ai` | Base URL of the vroxy deployment.                     |
| `enabled`       | `true` iff `api_key` present  | Master kill switch.                                                     |
| `auto_inject`   | `true`                        | Middleware appends the snippet before `</body>` on `text/html` responses. |
| `identify`      | *(auto-detect)*               | `->(controller) { {...} }`. Return `nil` to stay anonymous.             |
| `exclude_paths` | `[]`                          | Strings or Regexps matched against `request.path`; skipped by middleware. |
| `csp_nonce`     | `nil`                         | `->(controller) { controller.content_security_policy_nonce }` for strict CSP. |
| `identity_secret` | `ENV["VROXY_IDENTITY_SECRET"]` | Workspace identity-verification secret; signs the identify payload's access level so gated bot tools unlock. |
| `report_errors` | `nil` (auto: production + api_key) | Ship unhandled exceptions to the workspace Errors page. |
| `error_ignore`  | RecordNotFound, RoutingError, … | Exception class names (incl. subclasses) never reported. |

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

The middleware only rewrites a response when ALL of:

- Vroxy is enabled and `api_key` is set.
- `config.auto_inject` is true.
- `request.path` is not on `exclude_paths`.
- `Content-Type` matches `text/html`.
- Status is 2xx (not 204, not redirect, not error).
- Body contains a literal `</body>`.
- The helper wasn't already used on this request.

Anything else is a passthrough — the original response bytes are untouched.

## Development

```bash
bundle install
bundle exec rake test
```

## License

MIT.
