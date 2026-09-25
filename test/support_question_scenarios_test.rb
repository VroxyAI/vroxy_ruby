# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "support/safe_query_fixtures"

# Natural-language support questions → the exact safe_query payload the
# bot (or a host tool) must send. These are the dogfood shapes:
# Brevitas "how many leads on 123 Main St?" and similar Deal counts.
# The wire path (signed middleware) is exercised too so a gem bump that
# breaks the endpoint fails here, not only in the runner unit tests.
class SupportQuestionScenariosTest < Minitest::Test
  SECRET = "qs_#{'s' * 40}"

  def setup
    super
    SafeQueryFixtures.reseed!
    @config = Vroxy.configuration.safe_query
    @config.secret = SECRET
    SafeQueryFixtures.declare_default_allowlist!(@config)
  end

  def run_query(payload)
    Vroxy::SafeQuery::Runner.execute(payload, config: @config)
  end

  def post_signed(payload)
    body = JSON.generate(payload)
    timestamp = Time.now.to_i.to_s
    nonce = "nonce-#{Time.now.to_f.to_s.delete('.')}"
    middleware = Vroxy::SafeQuery::Middleware.new(->(_) { [404, {}, []] })
    status, _headers, chunks = middleware.call(
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/vroxy/query",
      "rack.input" => StringIO.new(body),
      "HTTP_X_VROXY_TIMESTAMP" => timestamp,
      "HTTP_X_VROXY_NONCE" => nonce,
      "HTTP_X_VROXY_SIGNATURE" => Vroxy::SafeQuery::Signature.sign(
        secret: SECRET, timestamp: timestamp, nonce: nonce, body: body
      )
    )
    [status, JSON.parse(chunks.join)]
  end

  # "How many leads did I get on the 123 Main St property?"
  # Archived deal id=4 is also Main St but the allowlist scope drops it.
  def test_deals_on_a_named_property
    payload = {
      "model" => "Deal",
      "scope" => [{ "where" => { "property_address" => "123 Main St" } }],
      "terminal" => "count"
    }
    result = run_query(payload)
    assert result["ok"], result.inspect
    assert_equal 2, result["result"]
    assert_match(/property_address/i, result["sql"])

    status, body = post_signed(payload)
    assert_equal 200, status
    assert_equal 2, body["result"]
  end

  # "How many deals closed this week?"
  def test_deals_won_in_the_last_week
    payload = {
      "model" => "Deal",
      "scope" => [
        { "where" => { "status" => "won", "created_at_gte" => "7.days.ago" } }
      ],
      "terminal" => "count"
    }
    result = run_query(payload)
    assert result["ok"], result.inspect
    assert_equal 1, result["result"]
  end

  def test_an_undeclared_property_column_stays_unreachable
    @config.model "Deal",
                  columns: %w[id account_id status amount archived created_at],
                  scope: ->(rel) { rel.where(archived: false) }
    result = run_query(
      "model" => "Deal",
      "scope" => [{ "where" => { "property_address" => "123 Main St" } }],
      "terminal" => "count"
    )
    refute result["ok"]
    assert_match(/property_address/, result["error"])
  end
end
