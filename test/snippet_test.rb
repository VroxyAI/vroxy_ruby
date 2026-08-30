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

  def test_rendered_partials_forwarded_to_init_args
    Vroxy.configure { |c| c.api_key = "pk_1" }
    user = Struct.new(:id, :email, :role).new(1, "x@y.co", "admin")
    partials = [{ path: "app/views/posts/_row.html.erb", ms: 1.2 }]
    html = Vroxy::Snippet.render(InspectorController.new(user, partials))

    assert_includes html, "\"rendered_partials\":[{\"path\":\"app/views/posts/_row.html.erb\",\"ms\":1.2}]"
  end
end
