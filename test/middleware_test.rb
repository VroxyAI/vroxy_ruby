# frozen_string_literal: true

require "test_helper"

class MiddlewareTest < Minitest::Test
  include Rack::Test::Methods

  # Build a Rack app on the fly per test — the inner app + status /
  # headers / body are the actual variables we exercise here.
  def build_app(status: 200, headers: { "Content-Type" => "text/html" }, body: "<html><body>hi</body></html>", env_extras: {})
    inner = ->(env) {
      env.merge!(env_extras)
      [status, headers, [body]]
    }
    Ctovibe::Middleware.new(inner)
  end

  def app
    @app
  end

  def with_config
    Ctovibe.configure { |c| c.api_key = "pk_test" }
    yield
  end

  def test_injects_before_body_close_on_html
    with_config do
      @app = build_app
      get "/"
      assert_includes last_response.body, "widget.js?tenant=pk_test"
      assert_match(/<script[^>]+widget\.js[^>]*><\/script>\s*<\/body>/, last_response.body)
    end
  end

  def test_skips_non_html_responses
    with_config do
      @app = build_app(headers: { "Content-Type" => "application/json" }, body: '{"ok":true}')
      get "/"
      assert_equal '{"ok":true}', last_response.body
    end
  end

  def test_skips_when_disabled
    @app = build_app
    get "/"
    refute_includes last_response.body, "widget.js"
  end

  def test_skips_when_auto_inject_off
    Ctovibe.configure do |c|
      c.api_key     = "pk_test"
      c.auto_inject = false
    end
    @app = build_app
    get "/"
    refute_includes last_response.body, "widget.js"
  end

  def test_skips_excluded_paths
    Ctovibe.configure do |c|
      c.api_key       = "pk_test"
      c.exclude_paths = [%r{\A/admin}]
    end
    @app = build_app
    get "/admin/dashboard"
    refute_includes last_response.body, "widget.js"
  end

  def test_skips_when_helper_already_rendered
    with_config do
      @app = build_app(env_extras: { Ctovibe::Helper::RENDERED_ENV_KEY => true })
      get "/"
      refute_includes last_response.body, "widget.js"
    end
  end

  def test_skips_redirect_and_error_statuses
    with_config do
      @app = build_app(status: 302, headers: { "Content-Type" => "text/html" }, body: "<html><body></body></html>")
      get "/"
      refute_includes last_response.body, "widget.js"
    end
  end

  def test_skips_when_no_body_close_tag
    with_config do
      @app = build_app(body: "<div>fragment</div>")
      get "/"
      assert_equal "<div>fragment</div>", last_response.body
    end
  end

  def test_updates_content_length_when_present
    with_config do
      original = "<html><body>hi</body></html>"
      @app = build_app(headers: { "Content-Type" => "text/html", "Content-Length" => original.bytesize.to_s }, body: original)
      get "/"
      assert_equal last_response.body.bytesize.to_s, last_response.headers["Content-Length"]
    end
  end
end
