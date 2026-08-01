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
    Ctovibe.configure { |c| c.enabled = false }
    assert_equal "", Ctovibe::Snippet.render(FakeController.new)
  end

  def test_empty_when_api_key_missing
    assert_equal "", Ctovibe::Snippet.render(FakeController.new)
  end

  def test_renders_loader_tag_only_when_no_identity
    Ctovibe.configure { |c| c.api_key = "pk_test123" }
    html = Ctovibe::Snippet.render(FakeController.new)

    assert_includes html, %(src="https://ctovibe.ai/widget.js?tenant=pk_test123")
    assert_includes html, %(data-tenant="pk_test123")
    assert_includes html, "async"
    refute_includes html, "ctovibe(\"identify\""
  end

  def test_renders_identify_when_current_user_present
    Ctovibe.configure { |c| c.api_key = "pk_1" }

    user = Struct.new(:id, :email, :full_name, :role)
      .new(7, "u@ex.com", "User Seven", "admin")

    html = Ctovibe::Snippet.render(FakeController.new(user))

    assert_includes html, "ctovibe(\"identify\""
    assert_includes html, "\"email\":\"u@ex.com\""
    assert_includes html, "\"name\":\"User Seven\""
    assert_includes html, "\"external_id\":\"7\""
    # `role` is a customer-arbitrary key, so it lands under meta.
    assert_includes html, "\"meta\":{\"role\":\"admin\"}"
  end

  def test_url_encodes_api_key_in_src
    Ctovibe.configure { |c| c.api_key = "pk with spaces" }
    html = Ctovibe::Snippet.render(FakeController.new)
    assert_includes html, "tenant=pk+with+spaces"
  end

  def test_respects_custom_endpoint
    Ctovibe.configure do |c|
      c.api_key  = "pk_1"
      c.endpoint = "https://ctovibe.test/"
    end
    html = Ctovibe::Snippet.render(FakeController.new)
    assert_includes html, "https://ctovibe.test/widget.js"
    refute_includes html, "ctovibe.test//widget", "trailing slash must be trimmed"
  end

  def test_csp_nonce_is_applied_when_configured
    Ctovibe.configure do |c|
      c.api_key   = "pk_1"
      c.csp_nonce = ->(_ctrl) { "abc123" }
    end

    user = Struct.new(:id, :email).new(1, "x@y.co")
    html = Ctovibe::Snippet.render(FakeController.new(user))

    assert_includes html, %(<script nonce="abc123">)
  end

  def test_explicit_meta_wins_over_auto_extras
    Ctovibe.configure do |c|
      c.api_key  = "pk_1"
      c.identify = ->(_) { { email: "x@y.co", role: "admin", meta: { role: "override" } } }
    end
    html = Ctovibe::Snippet.render(FakeController.new)
    assert_includes html, "\"meta\":{\"role\":\"override\"}"
  end
end
