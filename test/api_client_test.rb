# frozen_string_literal: true

require "test_helper"

class ApiClientTest < Minitest::Test
  def setup
    Vroxy.reset_configuration!
    @client = Vroxy::ApiClient.new(endpoint: "https://vroxy.ai", secret_token: "sekret")
  end

  def with_stubbed_http(code:, body:)
    response = Struct.new(:code, :body).new(code, body)
    http = Object.new
    captured = {}
    http.define_singleton_method(:request) do |req|
      captured[:method] = req.method
      captured[:path]   = req.path
      captured[:body]   = req.body
      captured[:auth]   = req["Authorization"]
      response
    end
    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &blk) { blk.call(http) }) do
      yield
    end
    captured
  end

  def test_create_share_post_posts_the_social_endpoint
    captured = with_stubbed_http(code: "201", body: '{"post":{"caption":"hi"}}') do
      @client.create_share_post(caption: "hi", media_url: "https://example.com/a.jpg", media_kind: "image")
    end

    assert_equal "POST", captured[:method]
    assert_equal "/api/v1/social", captured[:path]
    assert_equal "Bearer sekret", captured[:auth]
    payload = JSON.parse(captured[:body])
    assert_equal "hi", payload.dig("post", "caption")
    assert_equal "image", payload.dig("post", "media_kind")
  end

  def test_list_share_posts_gets_the_social_endpoint
    captured = with_stubbed_http(code: "200", body: '{"social":[]}') do
      @client.list_share_posts
    end

    assert_equal "GET", captured[:method]
    assert_equal "/api/v1/social", captured[:path]
  end

  def test_list_share_posts_appends_a_status_filter
    captured = with_stubbed_http(code: "200", body: '{"social":[]}') do
      @client.list_share_posts(status: "draft")
    end

    assert_equal "/api/v1/social?status=draft", captured[:path]
  end
end
