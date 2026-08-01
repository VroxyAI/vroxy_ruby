# ctovibe

Drop-in Rails gem for the [ctovibe](https://ctovibe.ai) support widget.

Set your API key, and the widget snippet auto-injects on every HTML response — with the current user's email, name, and role forwarded to `ctovibe.identify()` so support conversations land pre-identified.

## Install

```ruby
# Gemfile
gem "ctovibe"
```

```bash
bundle install
bin/rails generate ctovibe:install
```

Then set your key (from https://ctovibe.ai → workspace settings):

```bash
# .env / your secret manager
CTOVIBE_API_KEY=pk_live_...
```

That's it. Every `text/html` response now carries the loader script + an `identify()` call for the current user.

## What gets injected

Two `<script>` tags appended before `</body>`:

```html
<script src="https://ctovibe.ai/widget.js?tenant=pk_live_..." data-tenant="pk_live_..." async></script>
<script>
  (function(){
    window.ctovibe = window.ctovibe || function(){ (window.ctovibe.q = window.ctovibe.q || []).push(arguments); };
    window.ctovibe("identify", {"email":"ada@example.com","name":"Ada Lovelace","external_id":"42","meta":{"role":"admin"}});
  })();
</script>
```

The first script is the ctovibe loader (served by ctovibe.io). The second identifies the logged-in user via the same public `ctovibe(...)` API surface documented for hand-rolled installs — so migrating a customer between the two is a no-op on the widget side.

## Identity resolution

By default the gem reads `controller.current_user` and pulls:

| Field         | Source                                                   |
| ------------- | -------------------------------------------------------- |
| `external_id` | `user.id.to_s`                                           |
| `email`       | `user.email`                                             |
| `name`        | `user.full_name` → `user.name` → `first_name + last_name` |
| `role`        | `user.role` → `user.roles.first`                         |

Everything except `email` / `name` / `external_id` is forwarded under `meta` (ctovibe's arbitrary-attributes escape hatch), so `role: "admin"` becomes `meta: { role: "admin" }` on the wire.

Missing accessors are quietly skipped — a bare `User(id, email)` still yields a useful identify payload.

### Custom resolver

Override for non-Devise auth, multi-tenant scoping, or when your role model doesn't match the default sniffing:

```ruby
Ctovibe.configure do |config|
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

## Configuration reference

| Key             | Default                       | Purpose                                                                 |
| --------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `api_key`       | `ENV["CTOVIBE_API_KEY"]`      | Tenant public key (`pk_...`).                                           |
| `endpoint`      | `ENV["CTOVIBE_ENDPOINT"]` or `https://ctovibe.ai` | Base URL of the ctovibe deployment.                     |
| `enabled`       | `true` iff `api_key` present  | Master kill switch.                                                     |
| `auto_inject`   | `true`                        | Middleware appends the snippet before `</body>` on `text/html` responses. |
| `identify`      | *(auto-detect)*               | `->(controller) { {...} }`. Return `nil` to stay anonymous.             |
| `exclude_paths` | `[]`                          | Strings or Regexps matched against `request.path`; skipped by middleware. |
| `csp_nonce`     | `nil`                         | `->(controller) { controller.content_security_policy_nonce }` for strict CSP. |

## Manual placement (auto-inject off)

```ruby
Ctovibe.configure { |c| c.auto_inject = false }
```

```erb
<%# app/views/layouts/application.html.erb, before </body> %>
<%= ctovibe_snippet %>
```

Even with auto-inject on, calling `ctovibe_snippet` in a layout suppresses the middleware for that request (no double injection).

## Middleware safety rules

The middleware only rewrites a response when ALL of:

- Ctovibe is enabled and `api_key` is set.
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
