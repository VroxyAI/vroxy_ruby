# frozen_string_literal: true

require "test_helper"
require "json"

class SnippetSecurityTest < Minitest::Test
  SECRET = "is_TOPSECRETtopsecretTOPSECRETtopsecret12345678"
  TOKEN  = "sk_SERVERSIDEONLYtoken"

  class FakeController
    def initialize(user = nil, path: "posts", action: "index")
      @user   = user
      @path   = path
      @action = action
    end

    def current_user
      @user
    end

    def controller_path; @path; end
    def action_name;     @action; end
  end

  def identify_payload(html)
    match = html.match(/vroxy\("identify", (\{.*?\})\);/m)
    refute_nil match, "identify call not found in: #{html}"
    JSON.parse(match[1])
  end

  def script_count(html)
    html.scan(/<script\b/).size
  end

  def hmac(secret, *fields)
    OpenSSL::HMAC.hexdigest("SHA256", secret, fields.join("|"))
  end

  def server_verifies?(secret, payload)
    signature = payload["signature"].to_s
    return false if signature.empty? || secret.to_s.empty?
    fields = [ payload["external_id"].to_s, payload["email"].to_s, payload["level"].to_s ]
    return false if fields.any? { |f| f.include?("|") }
    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, fields.join("|"))
    Rack::Utils.secure_compare(expected, signature)
  end

  def render_for(identity, **config)
    Vroxy.configure do |c|
      c.api_key = "pk_1"
      c.identify = ->(_) { identity }
      config.each { |k, v| c.public_send("#{k}=", v) }
    end
    Vroxy::Snippet.render(FakeController.new)
  end

  def test_the_identity_secret_and_secret_token_never_reach_the_page
    [
      nil,
      { email: "anon-ish@ex.com" },
      { external_id: "1", email: "u@ex.com", role: "member" },
      { external_id: "2", email: "a@ex.com", role: "admin", meta: { note: "x" } }
    ].each do |identity|
      Vroxy.reset_configuration!
      html = render_for(identity, identity_secret: SECRET, secret_token: TOKEN)
      assert_includes html, "widget.js"
      refute_includes html, "TOPSECRET", "identity secret leaked for #{identity.inspect}"
      refute_includes html, TOKEN, "secret token leaked for #{identity.inspect}"
    end
  end

  def test_a_signed_payload_verifies_under_the_servers_own_algorithm
    [
      { external_id: "7", email: "u@ex.com", role: "admin" },
      { external_id: 42, email: "m@ex.com", role: "member" },
      { email: "only-email@ex.com" },
      { external_id: "ü42", email: "jürgen@exämple.de", name: "Jürgen" },
      { external_id: "9", email: "", name: "blank email is stripped" },
      { external_id: 0, role: "owner" }
    ].each do |identity|
      Vroxy.reset_configuration!
      payload = identify_payload(render_for(identity, identity_secret: SECRET))
      assert server_verifies?(SECRET, payload), "#{identity.inspect} -> #{payload.inspect}"
      refute server_verifies?("is_wrong", payload)
    end
  end

  def test_a_visitor_who_edits_the_signed_claims_fails_verification
    payload = identify_payload(
      render_for({ external_id: "7", email: "u@ex.com", role: "member" }, identity_secret: SECRET)
    )
    assert_equal "user", payload["level"]
    assert server_verifies?(SECRET, payload)
    refute server_verifies?(SECRET, payload.merge("level" => "admin"))
    refute server_verifies?(SECRET, payload.merge("email" => "boss@ex.com"))
    refute server_verifies?(SECRET, payload.merge("external_id" => "1"))
  end

  def test_signature_for_is_hmac_sha256_hex_over_the_pipe_joined_claims
    expected = OpenSSL::HMAC.hexdigest("SHA256", "is_key", "42|ada@example.com|admin")
    assert_equal expected, Vroxy::Identity.signature_for(
      external_id: 42, email: "ada@example.com", level: "admin", secret: "is_key"
    )
    assert_match(/\A[0-9a-f]{64}\z/, expected)
  end

  def test_signature_for_never_reorders_the_fields
    forward = Vroxy::Identity.signature_for(external_id: "a", email: "b", level: "c", secret: "s")
    swapped = Vroxy::Identity.signature_for(external_id: "b", email: "a", level: "c", secret: "s")
    refute_equal forward, swapped
  end

  def test_a_quote_in_the_endpoint_cannot_break_out_of_the_src_attribute
    html = render_for(nil, endpoint: %(https://evil.test/" onload="alert(1)))
    refute_includes html, %(" onload=")
    assert_includes html, "&quot; onload=&quot;alert(1)"
    assert_equal 1, script_count(html)
  end

  def test_an_api_key_with_markup_is_percent_encoded
    Vroxy.configure { |c| c.api_key = %(pk"><script>alert(1)</script>) }
    html = Vroxy::Snippet.render(FakeController.new)
    assert_equal 1, script_count(html)
    assert_includes html, "tenant=pk%22%3E%3Cscript%3Ealert%281%29%3C%2Fscript%3E"
  end

  def test_a_hostile_csp_nonce_is_attribute_escaped_on_every_tag
    html = render_for(
      { email: "u@ex.com", role: "admin" },
      identity_secret: "s",
      csp_nonce: ->(_) { %("><script>alert(1)</script>) }
    )
    assert_equal 3, script_count(html)
    assert_equal 3, html.scan(%(nonce="&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;")).size
  end

  def test_an_empty_nonce_renders_no_attribute
    html = render_for(nil, csp_nonce: ->(_) { "" })
    refute_includes html, "nonce"
  end

  def test_an_endpoint_cannot_close_the_inspector_module_script
    html = render_for(
      { email: "u@ex.com", role: "admin" },
      identity_secret: "s",
      endpoint: "https://vroxy.test/</script><script>alert(1)//"
    )
    inspector = html[html.index('<script type="module">')..]
    assert_equal 1, inspector.scan("</script>").size
  end

  def test_meta_keys_are_escaped_as_well_as_values
    html = render_for({ email: "a@b.c", meta: { "</script>" => "<!--", "plan" => "</SCRIPT >" } })
    assert_equal 2, html.scan(%r{</script>}i).size
    assert_equal({ "</script>" => "<!--", "plan" => "</SCRIPT >" }, identify_payload(html)["meta"])
  end

  def test_the_inspector_needs_an_admin_role_and_a_signed_admin_level
    [
      [ "s", { email: "u@ex.com", role: "owner" }, true ],
      [ "s", { email: "u@ex.com", meta: { role: "admin" } }, false ],
      [ "s", { email: "u@ex.com", meta: { role: "admin" }, level: "admin" }, true ],
      [ "s", { email: "u@ex.com", meta: { "role" => "admin" }, level: "admin" }, true ],
      [ "s", { email: "u@ex.com" }, false ],
      [ "s", { email: "u@ex.com", role: "admin", level: "user" }, false ],
      [ "s", { email: "u@ex.com", role: "Admin" }, false ],
      [ nil, { email: "u@ex.com", role: "admin" }, false ],
      [ nil, { email: "u@ex.com", role: "admin", level: "admin" }, false ],
      [ nil, { email: "u@ex.com", role: "admin", level: "admin", signature: "  " }, false ]
    ].each do |secret, identity, expected|
      Vroxy.reset_configuration!
      html = render_for(identity, identity_secret: secret)
      assert_equal expected, html.include?("admin_ui_inspector.js"), "#{secret.inspect} #{identity.inspect}"
    end
  end

  def test_a_host_signed_admin_with_an_admin_role_gets_the_inspector
    html = render_for(
      { external_id: "7", email: "u@ex.com", role: "admin", level: "admin",
        signature: hmac("elsewhere", "7", "u@ex.com", "admin") }
    )
    assert_includes html, "admin_ui_inspector.js"
  end

  def test_an_anonymous_visitor_gets_the_loader_and_nothing_else
    html = render_for(nil, identity_secret: "s")
    assert_equal 1, script_count(html)
    refute_includes html, "identify"
  end

  def test_an_identify_block_returning_a_non_hash_is_anonymous
    html = render_for([ { email: "a@b.c" } ])
    assert_equal 1, script_count(html)
  end

  def test_the_inspector_init_args_carry_controller_action_and_partials
    Vroxy.configure do |c|
      c.api_key = "pk_1"
      c.identity_secret = "s"
      c.identify = ->(_) { { email: "u@ex.com", role: "admin" } }
    end
    controller = FakeController.new(nil, path: "admin/orders", action: "show")
    controller.instance_variable_set(:@_vroxy_rendered_partials, [ "orders/_row" ])
    html = Vroxy::Snippet.render(controller)
    args = JSON.parse(html.match(/VroxyInspector\.init\((\{.*?\})\);/m)[1])
    assert_equal({ "tenant" => "pk_1", "endpoint" => "https://vroxy.ai",
                   "controller_action" => "admin/orders#show",
                   "rendered_partials" => [ "orders/_row" ] }, args)
  end

  def test_a_failing_csp_nonce_lookup_still_renders
    html = render_for({ email: "u@ex.com" }, csp_nonce: ->(_) { raise "no nonce" })
    assert_equal 2, script_count(html)
    refute_includes html, "nonce"
  end

  def test_a_nil_endpoint_costs_the_widget_not_the_page
    html = nil
    _out, err = capture_io { html = render_for(nil, endpoint: nil) }
    assert_equal "", html
    assert_match(/snippet render failed/, err)
  end

  def test_forcing_enabled_on_without_an_api_key_still_renders_nothing
    Vroxy.configure { |c| c.enabled = true }
    assert_equal "", Vroxy::Snippet.render(FakeController.new)
  end
end
