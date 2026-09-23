# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Vroxy
  class ApiClient
    class Error < StandardError; end

    def initialize(endpoint: nil, secret_token: nil)
      @endpoint     = (endpoint || Vroxy.configuration.endpoint).to_s
      @endpoint     = "https://vroxy.ai" if @endpoint.strip.empty?
      @secret_token = (secret_token || Vroxy.configuration.secret_token).to_s
    end

    def upsert_tool(attrs)
      request(:put, "/api/v1/tools/upsert", { "tool" => attrs })
    end

    def list_docs(status: nil)
      path = "/api/v1/docs"
      path = "#{path}?status=#{URI.encode_www_form_component(status)}" if status
      request(:get, path)
    end

    def create_doc(attrs)
      request(:post, "/api/v1/docs", { "doc" => attrs })
    end

    def update_doc(id, attrs)
      request(:patch, "/api/v1/docs/#{id}", { "doc" => attrs })
    end

    def publish_doc(id)
      request(:post, "/api/v1/docs/#{id}/publish")
    end

    private

    def request(method, path, body = nil)
      raise Error, "Vroxy.configuration.secret_token (or ENV VROXY_SECRET_TOKEN) is required" if @secret_token.strip.empty?

      uri = URI.parse("#{@endpoint.chomp('/')}#{path}")
      req = case method
            when :get    then Net::HTTP::Get.new(uri)
            when :post   then Net::HTTP::Post.new(uri)
            when :put    then Net::HTTP::Put.new(uri)
            when :patch  then Net::HTTP::Patch.new(uri)
            when :delete then Net::HTTP::Delete.new(uri)
            else
              raise ArgumentError, "unsupported method #{method}"
            end

      req["Authorization"] = "Bearer #{@secret_token}"
      req["Content-Type"]  = "application/json"
      req["Accept"]        = "application/json"
      req.body = JSON.generate(body) if body

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: 10, read_timeout: 15) { |http| http.request(req) }
      unless res.code.to_i.between?(200, 299)
        raise Error, "vroxy API #{method.upcase} #{path} failed: HTTP #{res.code} #{res.body.to_s[0, 300]}"
      end
      return {} if res.body.to_s.strip.empty?
      JSON.parse(res.body)
    rescue JSON::ParserError => e
      raise Error, "vroxy API returned non-JSON: #{e.message}"
    end
  end
end
