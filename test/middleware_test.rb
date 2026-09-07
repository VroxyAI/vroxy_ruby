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
    Vroxy::Middleware.new(inner)
  end

  def app
    @app
  end

  def with_config
    Vroxy.configure { |c| c.api_key = "pk_test" }
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
    Vroxy.configure do |c|
      c.api_key     = "pk_test"
      c.auto_inject = false
    end
    @app = build_app
    get "/"
    refute_includes last_response.body, "widget.js"
  end

  def test_skips_excluded_paths
    Vroxy.configure do |c|
      c.api_key       = "pk_test"
      c.exclude_paths = [%r{\A/admin}]
    end
    @app = build_app
    get "/admin/dashboard"
    refute_includes last_response.body, "widget.js"
  end

  def test_skips_when_helper_already_rendered
    with_config do
      @app = build_app(env_extras: { Vroxy::Helper::RENDERED_ENV_KEY => true })
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

  # A body that can only be enumerated once — a file iterator, an
  # Enumerator, anything not backed by an Array.  Reading it to look
  # for `</body>` consumes it, so handing the ORIGINAL object back on
  # a bail-out path serves the visitor a blank page.
  class OneShotBody
    def initialize(parts)
      @parts = parts
      @read  = false
    end

    def each(&blk)
      raise "body enumerated twice" if @read
      @read = true
      @parts.each(&blk)
    end

    def close; end
  end

  def call_middleware(status: 200, headers: { "Content-Type" => "text/html" }, body:, env: {})
    inner = ->(_e) { [ status, headers, body ] }
    st, hd, bd = Vroxy::Middleware.new(inner).call({ "PATH_INFO" => "/", "REQUEST_METHOD" => "GET" }.merge(env))
    out = +""
    bd.each { |part| out << part }
    [ st, hd, out ]
  end

  def test_one_shot_body_survives_when_there_is_no_body_tag
    with_config do
      _st, _hd, out = call_middleware(body: OneShotBody.new([ "<div>fragment</div>" ]))
      assert_equal "<div>fragment</div>", out
    end
  end

  def test_one_shot_body_survives_when_the_snippet_is_empty
    Vroxy.configure { |c| c.api_key = "pk_test"; c.enabled = true }
    Vroxy::Snippet.stub(:render, "") do
      _st, _hd, out = call_middleware(body: OneShotBody.new([ "<html><body>hi</body></html>" ]))
      assert_equal "<html><body>hi</body></html>", out
    end
  end

  def test_one_shot_body_is_injected_normally
    with_config do
      _st, _hd, out = call_middleware(body: OneShotBody.new([ "<html><body>hi" , "</body></html>" ]))
      assert_includes out, "widget.js?tenant=pk_test"
    end
  end

  def test_compressed_html_body_passes_through_untouched
    with_config do
      require "zlib"
      require "stringio"
      buffer = StringIO.new
      writer = Zlib::GzipWriter.new(buffer)
      writer.write("<html><body>hi</body></html>")
      writer.close
      gzipped = buffer.string

      _st, _hd, out = call_middleware(
        headers: { "Content-Type" => "text/html", "Content-Encoding" => "gzip" },
        body: [ gzipped ]
      )
      assert_equal gzipped.bytesize, out.bytesize, "a gzipped body must come back byte-identical"
      refute_includes out, "widget.js"
    end
  end

  # Compressed output is not always invalid UTF-8 — short bodies
  # and brotli/deflate frames can decode as text and even carry the
  # bytes `</body>`.  The declared encoding is the only reliable
  # signal that these bytes are not HTML we may append to.
  def test_encoded_body_that_happens_to_be_valid_text_is_left_alone
    with_config do
      encoded = "compressed-frame</body>"
      assert encoded.valid_encoding?

      _st, _hd, out = call_middleware(
        headers: { "Content-Type" => "text/html", "Content-Encoding" => "br" },
        body: [ encoded ]
      )
      assert_equal encoded, out
      refute_includes out, "widget.js"
    end
  end

  def test_identity_encoding_is_not_treated_as_compression
    with_config do
      _st, _hd, out = call_middleware(
        headers: { "Content-Type" => "text/html", "Content-Encoding" => "identity" },
        body: [ "<html><body>hi</body></html>" ]
      )
      assert_includes out, "widget.js"
    end
  end

  def test_binary_html_body_does_not_raise
    with_config do
      invalid = +"<html><body>hi"
      invalid << [ 0xff, 0xfe ].pack("C*")
      invalid << "</body></html>"
      invalid.force_encoding(Encoding::UTF_8)
      refute invalid.valid_encoding?

      _st, _hd, out = call_middleware(body: [ invalid ])
      assert_equal invalid.bytesize, out.bytesize
    end
  end

  def test_exclude_paths_match_the_browser_visible_path_of_a_mounted_app
    Vroxy.configure do |c|
      c.api_key       = "pk_test"
      c.exclude_paths = [ %r{\A/admin} ]
    end
    _st, _hd, out = call_middleware(
      body: [ "<html><body>hi</body></html>" ],
      env: { "SCRIPT_NAME" => "/admin", "PATH_INFO" => "/dashboard" }
    )
    refute_includes out, "widget.js", "an engine mounted at /admin is still /admin to the browser"
  end

  def test_exclude_paths_still_match_the_unmounted_path
    Vroxy.configure do |c|
      c.api_key       = "pk_test"
      c.exclude_paths = [ "/up" ]
    end
    _st, _hd, out = call_middleware(
      body: [ "<html><body>hi</body></html>" ],
      env: { "SCRIPT_NAME" => "/myapp", "PATH_INFO" => "/up" }
    )
    refute_includes out, "widget.js"
  end

  def test_streaming_body_without_each_is_left_alone
    with_config do
      streaming = Object.new
      def streaming.call(_stream); end
      inner = ->(_e) { [ 200, { "Content-Type" => "text/html" }, streaming ] }
      _st, _hd, body = Vroxy::Middleware.new(inner).call({ "PATH_INFO" => "/", "REQUEST_METHOD" => "GET" })
      assert_same streaming, body
    end
  end
end
