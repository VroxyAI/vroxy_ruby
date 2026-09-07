# frozen_string_literal: true

require "test_helper"

class SnippetTest < Minitest::Test
  class FakeController
    def initialize(user = nil)
      @user = user
    end

    def current_user
      @user
    end
  end

  def test_empty_when_disabled
    Vroxy.configure { |c| c.enabled = false }
    assert_equal "", Vroxy::Snippet.render(FakeController.new)
  end

  def test_empty_when_api_key_missing
    assert_equal "", Vroxy::Snippet.render(FakeController.new)
  end

  def test_renders_loader_tag_only_when_no_identity
    Vroxy.configure { |c| c.api_key = "pk_test123" }
    html = Vroxy::Snippet.render(FakeController.new)

    assert_includes html, %(src="https://vroxy.ai/widget.js?tenant=pk_test123")
    refute_includes html, "data-tenant"
    assert_includes html, "async"
    refute_includes html, "vroxy(\"identify\""
  end

  def test_renders_identify_when_current_user_present
    Vroxy.configure { |c| c.api_key = "pk_1" }

    user = Struct.new(:id, :email, :full_name, :role)
      .new(7, "u@ex.com", "User Seven", "admin")

    html = Vroxy::Snippet.render(FakeController.new(user))

    assert_includes html, "vroxy(\"identify\""
    assert_includes html, "\"email\":\"u@ex.com\""
    assert_includes html, "\"name\":\"User Seven\""
    assert_includes html, "\"external_id\":\"7\""
    # `role` is a customer-arbitrary key, so it lands under meta.
    assert_includes html, "\"meta\":{\"role\":\"admin\"}"
  end

  def test_url_encodes_api_key_in_src
    Vroxy.configure { |c| c.api_key = "pk with spaces" }
    html = Vroxy::Snippet.render(FakeController.new)
    assert_includes html, "tenant=pk+with+spaces"
  end

  def test_respects_custom_endpoint
    Vroxy.configure do |c|
      c.api_key  = "pk_1"
      c.endpoint = "https://vroxy.test/"
    end
    html = Vroxy::Snippet.render(FakeController.new)
    assert_includes html, "https://vroxy.test/widget.js"
    refute_includes html, "vroxy.test//widget", "trailing slash must be trimmed"
  end

  def test_csp_nonce_is_applied_when_configured
    Vroxy.configure do |c|
      c.api_key   = "pk_1"
      c.csp_nonce = ->(_ctrl) { "abc123" }
    end

    user = Struct.new(:id, :email).new(1, "x@y.co")
    html = Vroxy::Snippet.render(FakeController.new(user))

    assert_includes html, %(<script nonce="abc123">)
  end

  def test_explicit_meta_wins_over_auto_extras
    Vroxy.configure do |c|
      c.api_key  = "pk_1"
      c.identify = ->(_) { { email: "x@y.co", role: "admin", meta: { role: "override" } } }
    end
    html = Vroxy::Snippet.render(FakeController.new)
    assert_includes html, "\"meta\":{\"role\":\"override\"}"
  end

  # A controller-like double that exposes controller_path /
  # action_name so the inspector init args include a proper
  # `controller_action` string.  Also lets us stash an
  # `@_vroxy_rendered_partials` ivar for the tracker-integration
  # assertion.
  class InspectorController
    attr_accessor :_vroxy_rendered_partials

    def initialize(user, rendered = nil)
      @user = user
      instance_variable_set(:@_vroxy_rendered_partials, rendered) if rendered
    end

    def current_user; @user; end
    def controller_path; "posts"; end
    def action_name;     "index"; end
  end

  def test_admin_inspector_tag_emitted_for_admin_role
    Vroxy.configure { |c| c.api_key = "pk_1" }
    user = Struct.new(:id, :email, :full_name, :role)
      .new(7, "u@ex.com", "User Seven", "admin")

    html = Vroxy::Snippet.render(InspectorController.new(user))
    assert_includes html, "https://vroxy.ai/admin_ui_inspector.js"
    assert_includes html, "VroxyInspector.init("
    assert_includes html, "\"controller_action\":\"posts#index\""
  end

  def test_admin_inspector_tag_absent_for_non_admin_role
    Vroxy.configure { |c| c.api_key = "pk_1" }
    user = Struct.new(:id, :email, :full_name, :role)
      .new(7, "u@ex.com", "User Seven", "basic")

    html = Vroxy::Snippet.render(InspectorController.new(user))
    refute_includes html, "admin_ui_inspector.js"
    refute_includes html, "VroxyInspector"
  end

  def test_admin_inspector_tag_absent_when_anonymous
    Vroxy.configure { |c| c.api_key = "pk_1" }
    html = Vroxy::Snippet.render(InspectorController.new(nil))
    refute_includes html, "admin_ui_inspector.js"
  end

  def test_admin_roles_are_configurable
    Vroxy.configure do |c|
      c.api_key     = "pk_1"
      c.admin_roles = %w[manager]
    end
    user = Struct.new(:id, :email, :role).new(1, "x@y.co", "manager")
    html = Vroxy::Snippet.render(InspectorController.new(user))
    assert_includes html, "admin_ui_inspector.js"
  end

  # A support widget must never be the reason a customer's page
  # 500s.  auto_inject means the host app never asked us to run
  # inside its render at all, so a failure here drops the widget
  # and leaves the page alone — in EVERY environment, matching the
  # Node and Python SDKs.
  def test_a_raising_identify_block_never_breaks_the_page
    Vroxy.configure do |c|
      c.api_key  = "pk_1"
      c.identify = ->(_) { raise "current_user exploded" }
    end

    out, err = capture_io do
      assert_equal "", Vroxy::Snippet.render(FakeController.new)
    end
    assert_empty out
    assert_match(/current_user exploded/, err)
  end

  def test_a_raising_identify_block_still_does_not_raise_in_production
    original = ENV["RACK_ENV"]
    ENV["RACK_ENV"] = "production"
    Vroxy.configure do |c|
      c.api_key  = "pk_1"
      c.identify = ->(_) { raise "current_user exploded" }
    end

    capture_io { assert_equal "", Vroxy::Snippet.render(FakeController.new) }
  ensure
    ENV["RACK_ENV"] = original
  end

  # `|` is legal RFC 5322 atext, so `a|b@example.com` is a real
  # address a real customer can hold.  Signing it is refused (the
  # canonical string would be ambiguous) — but that refusal must
  # cost the visitor a widget, never the whole page.
  def test_an_unsignable_email_costs_the_widget_not_the_page
    Vroxy.configure do |c|
      c.api_key         = "pk_1"
      c.identity_secret = "is_sekrit"
    end
    user = Struct.new(:id, :email, :full_name, :role).new(7, "a|b@example.com", "Pipe Person", "admin")

    out, err = capture_io do
      assert_equal "", Vroxy::Snippet.render(FakeController.new(user))
    end
    assert_empty out
    assert_match(/must not contain/, err)
  end

  def test_the_signing_api_itself_still_refuses_an_ambiguous_claim
    assert_raises(ArgumentError) do
      Vroxy::Identity.signature_for(external_id: "a|b", email: "u@ex.com", level: "user", secret: "s")
    end
  end

  # Under the nonce-only `script-src` the README documents, an
  # un-nonced `<script src>` is blocked outright and the widget
  # never boots — the inline tags being nonced doesn't help.
  def test_csp_nonce_is_applied_to_the_loader_tag_too
    Vroxy.configure do |c|
      c.api_key   = "pk_1"
      c.csp_nonce = ->(_ctrl) { "abc123" }
    end

    html = Vroxy::Snippet.render(FakeController.new(Struct.new(:id, :email, :role).new(1, "x@y.co", "admin")))

    assert_includes html, %(<script src="https://vroxy.ai/widget.js?tenant=pk_1" nonce="abc123" async>)
    assert_equal 3, html.scan(%r{nonce="abc123"}).length,
                 "loader, identify and inspector tags each need the nonce"
  end

  def test_rendered_partials_forwarded_to_init_args
    Vroxy.configure { |c| c.api_key = "pk_1" }
    user = Struct.new(:id, :email, :role).new(1, "x@y.co", "admin")
    partials = [{ path: "app/views/posts/_row.html.erb", ms: 1.2 }]
    html = Vroxy::Snippet.render(InspectorController.new(user, partials))

    assert_includes html, "\"rendered_partials\":[{\"path\":\"app/views/posts/_row.html.erb\",\"ms\":1.2}]"
  end
end
