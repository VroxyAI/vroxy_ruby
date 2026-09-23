# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class ToolsEndpointTest < Minitest::Test
  def setup
    Vroxy.reset_configuration!
    @secret = "a" * 32
    Vroxy.configure do |c|
      c.safe_query.secret = @secret
      c.tool "lookup_order" do |t|
        t.description "Look up an order"
        t.access :user
        t.param "order_id", "Order number", required: true
        t.handle { |args| { "order_id" => args["order_id"], "status" => "shipped" } }
      end
    end
  end

  def teardown
    Vroxy.reset_configuration!
  end

  def signed_env(path, body)
    ts = Time.now.to_i.to_s
    nonce = "n" * 16
    sig = Vroxy::SafeQuery::Signature.sign(secret: @secret, timestamp: ts, nonce: nonce, body: body)
    Rack::MockRequest.env_for(path, method: "POST", input: body).merge(
      "HTTP_X_VROXY_TIMESTAMP" => ts,
      "HTTP_X_VROXY_NONCE"     => nonce,
      "HTTP_X_VROXY_SIGNATURE" => sig,
      "CONTENT_TYPE"           => "application/json"
    )
  end

  def test_host_tool_runs_the_handler
    body = JSON.generate({ "arguments" => { "order_id" => "A-1" } })
    status, _headers, response = Vroxy::Tools::Endpoint.call(signed_env("/vroxy/tools/lookup_order", body))
    assert_equal 200, status
    payload = JSON.parse(response.join)
    assert payload["ok"]
    assert_equal "shipped", payload["result"]["status"]
    assert_equal "A-1", payload["result"]["order_id"]
  end

  def test_unknown_tool_is_404
    body = "{}"
    status, _, response = Vroxy::Tools::Endpoint.call(signed_env("/vroxy/tools/nope", body))
    assert_equal 404, status
    assert_equal "unknown tool", JSON.parse(response.join)["error"]
  end

  def test_bad_signature_is_401
    body = "{}"
    env = signed_env("/vroxy/tools/lookup_order", body)
    env["HTTP_X_VROXY_SIGNATURE"] = "v1=" + ("0" * 64)
    status, _, _ = Vroxy::Tools::Endpoint.call(env)
    assert_equal 401, status
  end

  def test_definition_defaults_host_when_handle_present
    tool = Vroxy.configuration.tools["lookup_order"]
    assert_equal "host", tool.resolved_kind
    assert_equal "user", tool.access
  end

  def test_link_tool_requires_url_template
    err = assert_raises(ArgumentError) do
      Vroxy.configure do |c|
        c.tool "broken_link" do |t|
          t.description "x"
          t.kind :link
        end
      end
    end
    assert_match(/url_template/, err.message)
  end
end
