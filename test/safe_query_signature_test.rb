# frozen_string_literal: true

require "test_helper"
require "json"

class SafeQuerySignatureTest < Minitest::Test
  VECTORS = JSON.parse(
    File.read(File.expand_path("vectors/safe_query_signature_vectors.json", __dir__))
  ).freeze

  Signature = Vroxy::SafeQuery::Signature

  def signable
    VECTORS.reject { |v| v["rejected"] }
  end

  def test_every_signable_vector_reproduces_its_signature
    signable.each do |vector|
      actual = Signature.sign(
        secret: vector["secret"], timestamp: vector["timestamp"],
        nonce: vector["nonce"], body: vector["body"]
      )
      assert_equal vector["signature"], actual, vector["name"]
    end
  end

  def test_every_signable_vector_verifies
    signable.each do |vector|
      assert Signature.verify(
        secret: vector["secret"], timestamp: vector["timestamp"],
        nonce: vector["nonce"], body: vector["body"], signature: vector["signature"]
      ), vector["name"]
    end
  end

  def test_every_rejected_vector_refuses_to_sign
    VECTORS.select { |v| v["rejected"] }.each do |vector|
      assert_raises(ArgumentError, vector["name"]) do
        Signature.sign(
          secret: vector["secret"], timestamp: vector["timestamp"],
          nonce: vector["nonce"], body: vector["body"]
        )
      end
    end
  end

  def test_every_rejected_vector_fails_verification
    VECTORS.select { |v| v["rejected"] }.each do |vector|
      refute Signature.verify(
        secret: vector["secret"], timestamp: vector["timestamp"],
        nonce: vector["nonce"], body: vector["body"],
        signature: "v1=#{'0' * 64}"
      ), vector["name"]
    end
  end

  def test_signatures_are_unique_per_field
    digests = signable.map { |v| v["signature"] }
    assert_equal digests.length, digests.uniq.length,
                 "two vectors differing only in secret/timestamp/nonce/body share a signature"
  end

  def test_a_tampered_body_does_not_verify
    vector = signable.first
    refute Signature.verify(
      secret: vector["secret"], timestamp: vector["timestamp"], nonce: vector["nonce"],
      body: "#{vector['body']} ", signature: vector["signature"]
    )
  end

  def test_a_different_secret_does_not_verify
    vector = signable.first
    refute Signature.verify(
      secret: "#{vector['secret']}x", timestamp: vector["timestamp"], nonce: vector["nonce"],
      body: vector["body"], signature: vector["signature"]
    )
  end

  def test_an_unversioned_digest_does_not_verify
    vector = signable.first
    refute Signature.verify(
      secret: vector["secret"], timestamp: vector["timestamp"], nonce: vector["nonce"],
      body: vector["body"], signature: vector["signature"].delete_prefix("v1=")
    )
  end

  def test_a_blank_signature_does_not_verify
    vector = signable.first
    [ nil, "", "v1=", "v1=zz", "v2=#{'a' * 64}" ].each do |candidate|
      refute Signature.verify(
        secret: vector["secret"], timestamp: vector["timestamp"], nonce: vector["nonce"],
        body: vector["body"], signature: candidate
      ), candidate.inspect
    end
  end

  def test_signing_needs_a_secret
    assert_raises(ArgumentError) do
      Signature.sign(secret: "", timestamp: "1757280000", nonce: "nonce-abcdefgh", body: "{}")
    end
  end

  def test_the_identity_secret_never_produces_a_query_signature
    secret = "shared-secret-" + ("s" * 32)
    identity = Vroxy::Identity.signature_for(
      external_id: "7", email: "u@ex.com", level: "admin", secret: secret
    )
    query = Signature.sign(
      secret: secret, timestamp: "1757280000", nonce: "nonce-abcdefgh", body: "{}"
    )
    refute_equal identity, query.delete_prefix("v1=")
  end

  def test_freshness_window
    now = 1_757_280_000
    assert Signature.fresh_timestamp?(now, tolerance: 300, now: now)
    assert Signature.fresh_timestamp?(now - 299, tolerance: 300, now: now)
    assert Signature.fresh_timestamp?(now + 299, tolerance: 300, now: now)
    refute Signature.fresh_timestamp?(now - 301, tolerance: 300, now: now)
    refute Signature.fresh_timestamp?(now + 301, tolerance: 300, now: now)
    refute Signature.fresh_timestamp?("nope", tolerance: 300, now: now)
  end
end
