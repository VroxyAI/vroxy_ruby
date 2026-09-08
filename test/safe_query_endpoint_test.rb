# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "support/safe_query_fixtures"

class SafeQueryEndpointTest < Minitest::Test
  SECRET = "qs_#{'a' * 40}"

  def setup
    super
    SafeQueryFixtures.reseed!
    @config = Vroxy.configuration.safe_query
    @config.secret = SECRET
    SafeQueryFixtures.declare_default_allowlist!(@config)
    @nonce_seq = 0
  end

  def next_nonce
    @nonce_seq += 1
    format("nonce-%08d", @nonce_seq)
  end

  def env_for(body, method: "POST", timestamp: Time.now.to_i.to_s, nonce: nil, signature: :sign, path: nil)
    nonce ||= next_nonce
    signature = if signature != :sign
                  signature
                elsif timestamp
                  Vroxy::SafeQuery::Signature.sign(
                    secret: SECRET, timestamp: timestamp, nonce: nonce, body: body
                  )
                else
                  "v1=#{'0' * 64}"
                end

    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path || @config.path,
      "rack.input"     => StringIO.new(body)
    }
    env["HTTP_X_VROXY_TIMESTAMP"] = timestamp if timestamp
    env["HTTP_X_VROXY_NONCE"]     = nonce if nonce
    env["HTTP_X_VROXY_SIGNATURE"] = signature if signature
    env
  end

  def post(payload, **options)
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    status, headers, chunks = Vroxy::SafeQuery::Endpoint.call(env_for(body, **options))
    [ status, headers, JSON.parse(chunks.join) ]
  end

  def test_a_signed_query_answers
    status, headers, body = post({ "model" => "Deal", "terminal" => "count" })
    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]
    assert_equal "no-store", headers["cache-control"]
    assert body["ok"]
    assert_equal 39, body["result"]
  end

  def test_an_unsigned_request_is_refused
    status, _headers, body = post({ "model" => "Deal", "terminal" => "count" }, signature: nil)
    assert_equal 401, status
    refute body["ok"]
    assert_match(/missing signature headers/, body["error"])
  end

  def test_a_request_with_no_timestamp_is_refused
    status, = post({ "model" => "Deal", "terminal" => "count" }, timestamp: nil)
    assert_equal 401, status
  end

  def test_a_request_with_no_nonce_is_refused
    body      = JSON.generate({ "model" => "Deal", "terminal" => "count" })
    timestamp = Time.now.to_i.to_s
    signature = Vroxy::SafeQuery::Signature.sign(
      secret: SECRET, timestamp: timestamp, nonce: "nonce-00000001", body: body
    )
    env = env_for(body, timestamp: timestamp, nonce: nil, signature: signature)
    env.delete("HTTP_X_VROXY_NONCE")
    status, = Vroxy::SafeQuery::Endpoint.call(env)
    assert_equal 401, status
  end

  def test_a_mis_signed_request_is_refused
    status, _headers, body = post({ "model" => "Deal", "terminal" => "count" },
                                  signature: "v1=#{'0' * 64}")
    assert_equal 401, status
    assert_match(/signature mismatch/, body["error"])
  end

  def test_a_signature_from_another_secret_is_refused
    payload   = JSON.generate({ "model" => "Deal", "terminal" => "count" })
    timestamp = Time.now.to_i.to_s
    nonce     = next_nonce
    forged    = Vroxy::SafeQuery::Signature.sign(
      secret: "qs_#{'z' * 40}", timestamp: timestamp, nonce: nonce, body: payload
    )
    status, _headers, body = post(payload, timestamp: timestamp, nonce: nonce, signature: forged)
    assert_equal 401, status
    assert_match(/signature mismatch/, body["error"])
  end

  def test_the_identity_secret_cannot_authenticate_a_query
    Vroxy.configuration.identity_secret = SECRET
    payload   = JSON.generate({ "model" => "Deal", "terminal" => "count" })
    timestamp = Time.now.to_i.to_s
    nonce     = next_nonce
    identity_style = "v1=#{Vroxy::Identity.signature_for(
      external_id: timestamp, email: nonce, level: payload, secret: SECRET
    )}"

    status, = post(payload, timestamp: timestamp, nonce: nonce, signature: identity_style)
    assert_equal 401, status
  end

  def test_a_tampered_body_is_refused
    payload   = JSON.generate({ "model" => "Deal", "terminal" => "count" })
    timestamp = Time.now.to_i.to_s
    nonce     = next_nonce
    signature = Vroxy::SafeQuery::Signature.sign(
      secret: SECRET, timestamp: timestamp, nonce: nonce, body: payload
    )
    swapped = JSON.generate({ "model" => "Account", "terminal" => "count" })

    status, _headers, body = post(swapped, timestamp: timestamp, nonce: nonce, signature: signature)
    assert_equal 401, status
    assert_match(/signature mismatch/, body["error"])
  end

  def test_a_replayed_body_is_refused
    payload   = JSON.generate({ "model" => "Deal", "terminal" => "count" })
    timestamp = Time.now.to_i.to_s
    nonce     = next_nonce
    signature = Vroxy::SafeQuery::Signature.sign(
      secret: SECRET, timestamp: timestamp, nonce: nonce, body: payload
    )

    first, = post(payload, timestamp: timestamp, nonce: nonce, signature: signature)
    assert_equal 200, first

    status, _headers, body = post(payload, timestamp: timestamp, nonce: nonce, signature: signature)
    assert_equal 401, status
    assert_match(/nonce already used/, body["error"])
  end

  def test_a_stale_timestamp_is_refused
    stale = (Time.now.to_i - @config.timestamp_tolerance - 60).to_s
    status, _headers, body = post({ "model" => "Deal", "terminal" => "count" }, timestamp: stale)
    assert_equal 401, status
    assert_match(/timestamp outside/, body["error"])
  end

  def test_a_far_future_timestamp_is_refused
    ahead = (Time.now.to_i + @config.timestamp_tolerance + 60).to_s
    status, = post({ "model" => "Deal", "terminal" => "count" }, timestamp: ahead)
    assert_equal 401, status
  end

  def test_a_malformed_nonce_is_refused
    [ "short", "nonce with spaces", "nonce\nwith-newline", "n" * 400 ].each do |nonce|
      status, = post({ "model" => "Deal", "terminal" => "count" }, nonce: nonce, signature: "v1=#{'0' * 64}")
      assert_equal 401, status, nonce.inspect
    end
  end

  def test_a_stale_request_never_reaches_the_nonce_store
    stale = (Time.now.to_i - @config.timestamp_tolerance - 60).to_s
    post({ "model" => "Deal", "terminal" => "count" }, timestamp: stale)
    assert_equal 0, @config.nonce_store.size
  end

  def test_a_mis_signed_request_never_reaches_the_nonce_store
    post({ "model" => "Deal", "terminal" => "count" }, signature: "v1=#{'1' * 64}")
    assert_equal 0, @config.nonce_store.size
  end

  def test_a_get_is_refused
    status, _headers, body = post({ "model" => "Deal", "terminal" => "count" }, method: "GET")
    assert_equal 405, status
    refute body["ok"]
  end

  def test_an_oversized_body_is_refused
    padding = "x" * (Vroxy::SafeQuery::Config::MAX_BODY_BYTES + 100)
    status, _headers, body = post({ "model" => "Deal", "terminal" => "count", "pad" => padding })
    assert_equal 413, status
    assert_match(/too large/, body["error"])
  end

  def test_malformed_json_is_refused
    status, _headers, body = post("{not json", signature: :sign)
    assert_equal 400, status
    assert_match(/JSON object/, body["error"])
  end

  def test_a_json_array_body_is_refused
    status, = post("[1,2,3]")
    assert_equal 400, status
  end

  def test_a_refused_query_answers_422_with_the_reason
    status, _headers, body = post({ "model" => "Ledger", "terminal" => "count" })
    assert_equal 422, status
    refute body["ok"]
    assert_match(/not exposed to vroxy/, body["error"])
  end

  def test_the_rate_limit_bites
    @config.max_requests_per_minute = 3
    4.times.map { post({ "model" => "Deal", "terminal" => "count" }) }.tap do |responses|
      assert_equal [ 200, 200, 200, 429 ], responses.map(&:first)
      assert_match(/rate limit/, responses.last[2]["error"])
    end
  end

  def test_a_zero_rate_limit_closes_the_endpoint
    @config.max_requests_per_minute = 0
    status, = post({ "model" => "Deal", "terminal" => "count" })
    assert_equal 429, status
  end

  def test_the_endpoint_is_invisible_when_no_secret_is_set
    @config.secret = ""
    status, _headers, body = post({ "model" => "Deal", "terminal" => "count" }, signature: nil)
    assert_equal 404, status
    refute body["ok"]
  end

  def test_the_endpoint_is_invisible_when_no_model_is_declared
    Vroxy.reset_configuration!
    config = Vroxy.configuration.safe_query
    config.secret = SECRET
    status, = post({ "model" => "Deal", "terminal" => "count" }, signature: nil)
    assert_equal 404, status
    assert_empty config.model_names
  end

  def test_describe_lists_only_declared_columns
    status, _headers, body = post({ "describe" => true })
    assert_equal 200, status
    assert body["ok"]

    names = body["models"].map { |m| m["name"] }
    assert_equal %w[Deal Account], names

    deal = body["models"].find { |m| m["name"] == "Deal" }
    refute_includes deal["columns"], "secret_note"
    assert deal["scoped"]

    account = body["models"].find { |m| m["name"] == "Account" }
    refute_includes account["columns"], "api_key"
  end

  def test_describe_still_needs_a_signature
    status, = post({ "describe" => true }, signature: nil)
    assert_equal 401, status
  end

  def test_describe_publishes_the_grammar
    _status, _headers, body = post({ "describe" => true })
    assert_equal Vroxy::SafeQuery::Runner::TERMINALS, body["grammar"]["terminals"]
    assert_equal Vroxy::SafeQuery::Runner::SCOPE_STEPS, body["grammar"]["scope_steps"]
  end

  def test_no_write_reaches_the_database_through_the_endpoint
    before = Deal.count
    post({ "model" => "Deal", "terminal" => "delete_all" })
    post({ "model" => "Deal", "scope" => [ { "where" => { "status" => "'; DELETE FROM deals; --" } } ],
           "terminal" => "count" })
    assert_equal before, Deal.count
  end

  def test_a_vector_signature_still_needs_a_fresh_timestamp
    vector = JSON.parse(
      File.read(File.expand_path("vectors/safe_query_signature_vectors.json", __dir__))
    ).find { |v| v["name"] == "describe request" }

    @config.secret = vector["secret"]
    @config.timestamp_tolerance = 900

    env = env_for(vector["body"], timestamp: vector["timestamp"], nonce: vector["nonce"],
                                  signature: vector["signature"])
    status, = Vroxy::SafeQuery::Endpoint.call(env)
    assert_equal 401, status, "the vector's fixed timestamp is far outside any live window"

    assert Vroxy::SafeQuery::Signature.verify(
      secret: vector["secret"], timestamp: vector["timestamp"], nonce: vector["nonce"],
      body: vector["body"], signature: vector["signature"]
    )
  end
end
