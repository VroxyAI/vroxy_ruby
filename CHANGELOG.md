# Changelog

## 0.1.0

- Initial release.
- `Ctovibe.configure` DSL: `api_key`, `endpoint`, `enabled`, `auto_inject`, `identify` block.
- `ctovibe_snippet` view helper for explicit placement.
- Rack middleware that auto-injects the loader script + `ctovibe.identify()` call before `</body>` on HTML responses.
- Default identify inference from `current_user` (id / email / name / role).
- `rails generate ctovibe:install` writes `config/initializers/ctovibe.rb`.
