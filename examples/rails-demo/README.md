# vroxy Rails demo

The smallest Rails app that shows the `vroxy` gem doing its job: install,
configure with a public key, sign the identify payload with
`identity_secret`, and gate the admin inspector on a role.

No database, no asset pipeline — one controller, one layout, one page.

## Run it

```bash
cd examples/rails-demo
bundle install
VROXY_API_KEY=your_tenant_public_key \
VROXY_IDENTITY_SECRET=your_workspace_identity_secret \
  bundle exec rackup -p 3000
```

Then open:

| URL              | What you should see in the page source                          |
| ---------------- | --------------------------------------------------------------- |
| `/?as=member`    | loader tag + `vroxy("identify", …)` with `"level":"user"`        |
| `/?as=admin`     | the same, `"level":"admin"`, plus the inspector `<script type="module">` |
| `/?as=anonymous` | loader tag only — no identify call                               |
| `/up`            | nothing; it's on `exclude_paths`                                 |

Both keys have working placeholder defaults, so it boots with no env vars
at all — the snippet renders, it just points at a tenant that isn't yours.
For the widget to actually boot in the browser you need a real public key
whose workspace **origin allowlist** includes `http://localhost:3000`.

## What each piece demonstrates

- **`Gemfile`** — installing from a path/git checkout. The gem is private
  and not on RubyGems.
- **`config/initializers/vroxy.rb`** — `api_key`, `identity_secret`, a
  custom `identify` block, `admin_roles`, `exclude_paths`.
- **`app/controllers/application_controller.rb`** — a `current_user` stand-in.
  Swap in Devise and delete the `identify` block; the gem sniffs
  `current_user` on its own.
- **`app/views/pages/home.html.erb`** — renders a partial as a collection,
  so an admin's inspector payload carries
  `rendered_partials: ["app/views/pages/_tip.html.erb"]`.

## About custom bot tools

Declare them in the initializer (`config.tool`) and run
`bin/rails vroxy:sync_tools`. Host tools execute Ruby in this app at
signed `POST /vroxy/tools/:name`; link/fetch tools sync their URL
templates into the workspace. Access levels still need
`config.identity_secret` so the widget can prove the visitor is a
signed-in user or admin.

Demo path for a gated host tool:

1. Declare the tool with `t.access :admin` and a `t.handle { … }` block.
2. Set `VROXY_IDENTITY_SECRET` + `VROXY_QUERY_SECRET`, sync tools, and
   point the workspace Host query connection at this app.
3. Load `/?as=admin` and ask the widget something that needs the tool.

## What has been verified

Against Ruby 3.4.9 and Rails 8.1.3:

- `bundle install` resolves this Gemfile (run as `--local`, against gems
  already on the machine — no fresh fetch from rubygems.org was exercised).
- `bundle exec rackup` boots, and every URL in the table above returns what
  it claims to: the widget tags on the three page routes, nothing on `/up`.
- The emitted signature equals an independently computed
  `HMAC-SHA256(secret, "external_id|email|level")`.
- An admin's inspector payload carries
  `rendered_partials: ["app/views/pages/_tip.html.erb"]`.

Not verified: anything requiring a real vroxy tenant. The widget bundle is
never fetched, no request reaches vroxy.ai, and the signature is checked
only against a local recomputation — not against the server that will
ultimately validate it.

No `Gemfile.lock` is committed; the gem is a path dependency here and the
lock would be pure churn.

## The matrix, checked

The table above is what you should see; `matrix_test.rb` asserts it
against rendered HTML so it cannot quietly stop being true:

```bash
bundle install
bundle exec ruby matrix_test.rb
```

Five rows — anonymous gets the loader and no identify at all, a member
signs at `user`, an admin at `admin`, the signature is a real
HMAC-SHA256 of `external_id|email|level` and the secret never reaches
the page, and an `exclude_paths` route carries no snippet.


## Local demo workspace

`vroxy_web` seeds a ready-made workspace for these examples — chat, tools
across all three access tiers, the feedback loop, and error reporting,
with every demo port already allowlisted:

```bash
cd ../vroxy_web && bin/rails db:seed:examples_tenant
```

It prints the two values below; they are fixed, dev-only, and safe to
paste here:

```
VROXY_API_KEY=vroxyexampleslocaldemo01
VROXY_IDENTITY_SECRET=vroxy-examples-identity-secret-local-dev-only012
VROXY_ENDPOINT=http://localhost:3000
```

Then visit `/boom` to raise a real 500 and confirm it lands in the
workspace under Errors.
