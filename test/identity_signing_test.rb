# frozen_string_literal: true

require "test_helper"
require "json"

# Signed identity claims — the level/signature pair the snippet
# emits when `identity_secret` is configured, which is what lets
# vroxy unlock access-gated bot tools for signed-in / admin
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
    match = html.match(/vroxy\("identify", (\{.*?\})\);/m)
    refute_nil match, "identify call not found in: #{html}"
    JSON.parse(match[1])
  end

  def test_level_for_admin_role
    Vroxy.configure { |c| c.api_key = "pk_1" }
    level = Vroxy::Identity.level_for({ role: "admin" }, Vroxy.configuration)
    assert_equal "admin", level
  end

  def test_level_for_plain_role_is_user
    Vroxy.configure { |c| c.api_key = "pk_1" }
    level = Vroxy::Identity.level_for({ role: "brokerbuyer" }, Vroxy.configuration)
    assert_equal "user", level
  end

  def test_level_for_respects_explicit_level
    Vroxy.configure { |c| c.api_key = "pk_1" }
    level = Vroxy::Identity.level_for({ role: "admin", level: "user" }, Vroxy.configuration)
    assert_equal "user", level
  end

  def test_no_secret_means_no_level_or_signature
    Vroxy.configure { |c| c.api_key = "pk_1" }
    html = Vroxy::Snippet.render(FakeController.new(FakeUser.new(7, "u@ex.com", "User Seven", "admin")))

    payload = identify_payload(html)
    refute payload.key?("level")
    refute payload.key?("signature")
  end

  def test_signed_payload_carries_level_role_and_matching_signature
    Vroxy.configure do |c|
      c.api_key         = "pk_1"
      c.identity_secret = "is_sekrit"
    end
    html = Vroxy::Snippet.render(FakeController.new(FakeUser.new(7, "u@ex.com", "User Seven", "admin")))

    payload = identify_payload(html)
    assert_equal "admin", payload["role"]
    assert_equal "admin", payload["level"]
    assert_equal hmac("is_sekrit", "7", "u@ex.com", "admin"), payload["signature"]
  end

  def test_non_admin_role_signs_as_user_level
    Vroxy.configure do |c|
      c.api_key         = "pk_1"
      c.identity_secret = "is_sekrit"
    end
    html = Vroxy::Snippet.render(FakeController.new(FakeUser.new(7, "u@ex.com", "User Seven", "member")))

    payload = identify_payload(html)
    assert_equal "user", payload["level"]
    assert_equal hmac("is_sekrit", "7", "u@ex.com", "user"), payload["signature"]
  end

  def test_signature_canonicalizes_nils_as_empty_strings
    sig = Vroxy::Identity.signature_for(external_id: nil, email: "a@b.c", level: "user", secret: "s")
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", "s", "|a@b.c|user"), sig
  end
  # A field containing the separator makes the canonical string
  # ambiguous — ("a|b", "c") and ("a", "b|c") both produce "a|b|c" —
  # so vroxy refuses the claim.  Signing one would hand back a
  # signature that can never verify; fail where the integrator sees it.
  def test_signature_for_refuses_a_separator_in_any_field
    [
      { external_id: "ext|pipe", email: "u@ex.com", level: "user" },
      { external_id: "7",        email: "pipe|@ex.com", level: "user" },
      { external_id: "7",        email: "u@ex.com", level: "us|er" }
    ].each do |claim|
      err = assert_raises(ArgumentError) do
        Vroxy::Identity.signature_for(**claim, secret: "s" * 48)
      end
      assert_match(/must not contain/, err.message)
    end
  end

  def test_signature_for_still_signs_ordinary_claims
    sig = Vroxy::Identity.signature_for(external_id: "7", email: "u@ex.com",
                                        level: "admin", secret: "s" * 48)
    assert_equal 64, sig.length
    assert_match(/\A[0-9a-f]{64}\z/, sig)
  end

  # An app that holds the secret elsewhere (a vault, another
  # service) can sign the claim itself.  Those two keys used to be
  # dropped — `level` silently, `signature` into `meta` — so the
  # visitor arrived unverified with no sign anything was wrong.
  def test_host_computed_level_and_signature_are_forwarded
    Vroxy.configure do |c|
      c.api_key  = "pk_1"
      c.identify = lambda { |_|
        { external_id: "7", email: "u@ex.com",
          level: "admin", signature: hmac("elsewhere", "7", "u@ex.com", "admin") }
      }
    end

    payload = identify_payload(Vroxy::Snippet.render(FakeController.new))
    assert_equal "admin", payload["level"]
    assert_equal hmac("elsewhere", "7", "u@ex.com", "admin"), payload["signature"]
    refute payload.key?("meta"), "signature must not be filed under meta"
  end

  def test_a_signature_without_a_level_is_not_forwarded
    Vroxy.configure do |c|
      c.api_key  = "pk_1"
      c.identify = ->(_) { { external_id: "7", email: "u@ex.com", signature: "deadbeef" } }
    end

    payload = identify_payload(Vroxy::Snippet.render(FakeController.new))
    refute payload.key?("signature"), "a signature with nothing to claim is meaningless"
    refute payload.key?("level")
    refute payload.key?("meta")
  end

  def test_configured_secret_wins_over_a_supplied_signature
    Vroxy.configure do |c|
      c.api_key         = "pk_1"
      c.identity_secret = "is_sekrit"
      c.identify        = ->(_) { { external_id: "7", email: "u@ex.com", level: "admin", signature: "forged" } }
    end

    payload = identify_payload(Vroxy::Snippet.render(FakeController.new))
    assert_equal hmac("is_sekrit", "7", "u@ex.com", "admin"), payload["signature"]
  end
end
