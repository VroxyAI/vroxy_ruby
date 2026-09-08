# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "support/safe_query_fixtures"

class SafeQueryMiddlewareTest < Minitest::Test
  SECRET = "qs_#{'a' * 40}"
  APP_RESPONSE = [ 200, { "content-type" => "text/html" }, [ "<html><body>host app</body></html>" ] ].freeze

  def setup
    super
    SafeQueryFixtures.reseed!
    @app        = ->(_env) { APP_RESPONSE }
    @middleware = Vroxy::SafeQuery::Middleware.new(@app)
    @config     = Vroxy.configuration.safe_query
  end

  def enable!
    @config.secret = SECRET
    SafeQueryFixtures.declare_default_allowlist!(@config)
  end

  def env_for(path, body: '{"model":"Deal","terminal":"count"}', script_name: nil)
    timestamp = Time.now.to_i.to_s
    nonce     = "nonce-#{Time.now.to_f.to_s.delete('.')}"
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO"      => path,
      "rack.input"     => StringIO.new(body),
      "HTTP_X_VROXY_TIMESTAMP" => timestamp,
      "HTTP_X_VROXY_NONCE"     => nonce,
      "HTTP_X_VROXY_SIGNATURE" => Vroxy::SafeQuery::Signature.sign(
        secret: SECRET, timestamp: timestamp, nonce: nonce, body: body
      )
    }
    env["SCRIPT_NAME"] = script_name if script_name
    env
  end

  def test_the_configured_path_is_served
    enable!
    status, headers, chunks = @middleware.call(env_for("/vroxy/query"))
    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]
    assert_equal 39, JSON.parse(chunks.join)["result"]
  end

  def test_every_other_path_passes_through
    enable!
    assert_equal APP_RESPONSE, @middleware.call(env_for("/dashboard"))
    assert_equal APP_RESPONSE, @middleware.call(env_for("/vroxy/query/extra"))
    assert_equal APP_RESPONSE, @middleware.call(env_for("/vroxy"))
  end

  def test_a_mounted_prefix_still_matches
    enable!
    status, = @middleware.call(env_for("/query", script_name: "/vroxy"))
    assert_equal 200, status
  end

  def test_the_path_is_pure_passthrough_until_it_is_configured
    assert_equal APP_RESPONSE, @middleware.call(env_for("/vroxy/query"))
  end

  def test_a_custom_path_moves_the_endpoint
    enable!
    @config.path = "/internal/vroxy-data"

    assert_equal APP_RESPONSE, @middleware.call(env_for("/vroxy/query"))
    status, = @middleware.call(env_for("/internal/vroxy-data"))
    assert_equal 200, status
  end

  def test_the_railtie_registers_the_middleware
    require "active_support/rails"
    require "rails/railtie"
    require "rails/configuration"
    require "action_dispatch"
    require "vroxy/railtie"

    app = Struct.new(:middleware).new(Rails::Configuration::MiddlewareStackProxy.new)
    Vroxy::Railtie.initializers.find { |i| i.name == "vroxy.safe_query" }.run(app)

    stack = ActionDispatch::MiddlewareStack.new
    app.middleware.merge_into(stack)
    refute_nil stack.middlewares.index { |m| m.klass == Vroxy::SafeQuery::Middleware }
  end
end
