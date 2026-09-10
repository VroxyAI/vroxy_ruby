# frozen_string_literal: true

ENV["VROXY_API_KEY"]         ||= "pk_demo_matrix_test"
ENV["VROXY_IDENTITY_SECRET"] ||= "demo_matrix_test_secret"
ENV["VROXY_ENDPOINT"]        ||= "https://vroxy.ai"

require_relative "config/environment"
require "rack/test"
require "minitest/autorun"
require "json"
require "openssl"

# The identity rules, checked against rendered HTML rather than read
# off a table in the README. The Express and Django demos already do
# this; the Rails one was the odd repo out.
class RailsDemoMatrixTest < Minitest::Test
  include Rack::Test::Methods

  def app = Rails.application

  def body_for(query)
    get "/#{query}"
    assert_equal 200, last_response.status
    last_response.body
  end

  def identify_payload(body)
    match = body.match(/vroxy\("identify",\s*(\{.*?\})\s*\)/m)
    refute_nil match, "no identify call in the page"
    JSON.parse(match[1])
  end

  def test_anonymous_gets_the_loader_and_no_identity_at_all
    body = body_for("?as=anonymous")
    assert_includes body, ENV.fetch("VROXY_API_KEY")
    refute_includes body, 'vroxy("identify"',
      "an anonymous visitor must not be identified as anybody"
  end

  def test_a_member_is_identified_at_user_level
    payload = identify_payload(body_for("?as=member"))
    assert_equal "user", payload["level"]
    assert_equal "grace@example.com", payload["email"]
  end

  def test_an_admin_is_identified_at_admin_level
    payload = identify_payload(body_for("?as=admin"))
    assert_equal "admin", payload["level"]
  end

  def test_the_claim_is_signed_and_the_secret_never_reaches_the_page
    body    = body_for("?as=admin")
    payload = identify_payload(body)

    expected = OpenSSL::HMAC.hexdigest(
      "SHA256", ENV.fetch("VROXY_IDENTITY_SECRET"),
      [ payload["external_id"], payload["email"], payload["level"] ].join("|")
    )
    assert_equal expected, payload["signature"],
      "an unsigned claim grants nothing, so the signature is the whole point"
    refute_includes body, ENV.fetch("VROXY_IDENTITY_SECRET"),
      "the signing secret must never be rendered into a page"
  end

  def test_an_excluded_path_carries_no_snippet
    get "/up"
    assert_equal 200, last_response.status
    refute_includes last_response.body, ENV.fetch("VROXY_API_KEY"),
      "exclude_paths means exclude"
  end
end
