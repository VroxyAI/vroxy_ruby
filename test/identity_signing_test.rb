# frozen_string_literal: true

require "test_helper"
require "json"

# Signed identity claims — the level/signature pair the snippet
# emits when `identity_secret` is configured, which is what lets
# ctovibe unlock access-gated bot tools for signed-in / admin
# visitors.
class IdentitySigningTest < Minitest::Test
  class FakeController
    def initialize(user = nil)
      @user = user
    end

    def current_user
      @user
    end
  end

  FakeUser = Struct.new(:id, :email, :full_name, :role)

  def hmac(secret, external_id, email, level)
    OpenSSL::HMAC.hexdigest("SHA256", secret, [ external_id, email, level ].join("|"))
  end

  def identify_payload(html)
    match = html.match(/ctovibe\("identify", (\{.*?\})\);/m)
    refute_nil match, "identify call not found in: #{html}"
    JSON.parse(match[1])
  end

  def test_level_for_admin_role
    Ctovibe.configure { |c| c.api_key = "pk_1" }
    level = Ctovibe::Identity.level_for({ role: "admin" }, Ctovibe.configuration)
    assert_equal "admin", level
  end

  def test_level_for_plain_role_is_user
    Ctovibe.configure { |c| c.api_key = "pk_1" }
    level = Ctovibe::Identity.level_for({ role: "brokerbuyer" }, Ctovibe.configuration)
    assert_equal "user", level
  end

  def test_level_for_respects_explicit_level
    Ctovibe.configure { |c| c.api_key = "pk_1" }
    level = Ctovibe::Identity.level_for({ role: "admin", level: "user" }, Ctovibe.configuration)
    assert_equal "user", level
  end

  def test_no_secret_means_no_level_or_signature
    Ctovibe.configure { |c| c.api_key = "pk_1" }
    html = Ctovibe::Snippet.render(FakeController.new(FakeUser.new(7, "u@ex.com", "User Seven", "admin")))

    payload = identify_payload(html)
    refute payload.key?("level")
    refute payload.key?("signature")
  end

  def test_signed_payload_carries_level_role_and_matching_signature
    Ctovibe.configure do |c|
      c.api_key         = "pk_1"
      c.identity_secret = "is_sekrit"
    end
    html = Ctovibe::Snippet.render(FakeController.new(FakeUser.new(7, "u@ex.com", "User Seven", "admin")))

    payload = identify_payload(html)
    assert_equal "admin", payload["role"]
    assert_equal "admin", payload["level"]
    assert_equal hmac("is_sekrit", "7", "u@ex.com", "admin"), payload["signature"]
  end

  def test_non_admin_role_signs_as_user_level
    Ctovibe.configure do |c|
      c.api_key         = "pk_1"
      c.identity_secret = "is_sekrit"
    end
    html = Ctovibe::Snippet.render(FakeController.new(FakeUser.new(7, "u@ex.com", "User Seven", "member")))

    payload = identify_payload(html)
    assert_equal "user", payload["level"]
    assert_equal hmac("is_sekrit", "7", "u@ex.com", "user"), payload["signature"]
  end

  def test_signature_canonicalizes_nils_as_empty_strings
    sig = Ctovibe::Identity.signature_for(external_id: nil, email: "a@b.c", level: "user", secret: "s")
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", "s", "|a@b.c|user"), sig
  end
end
