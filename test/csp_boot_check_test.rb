# frozen_string_literal: true

require "test_helper"
require "vroxy/csp_boot_check"

class CspBootCheckTest < Minitest::Test
  def test_warns_in_production_when_a_strict_csp_is_detected
    config = Struct.new(:csp_nonce, :endpoint).new(->(_) {}, "https://vroxy.ai")

    message = Vroxy::CspBootCheck.message_for(config: config, env: "production")

    assert_includes message, "wss://vroxy.ai"
    assert_includes message, "connect-src"
    assert_includes message, "Reconnecting"
  end

  def test_stays_quiet_when_no_csp_nonce_is_set
    config = Struct.new(:csp_nonce, :endpoint).new(nil, "https://vroxy.ai")

    assert_nil Vroxy::CspBootCheck.message_for(config: config, env: "production")
  end

  def test_stays_quiet_in_development
    config = Struct.new(:csp_nonce, :endpoint).new(->(_) {}, "https://vroxy.ai")

    assert_nil Vroxy::CspBootCheck.message_for(config: config, env: "development")
  end

  def test_derives_the_websocket_host_from_a_custom_endpoint
    config = Struct.new(:csp_nonce, :endpoint).new(->(_) {}, "https://vroxy.example")

    message = Vroxy::CspBootCheck.message_for(config: config, env: "production")

    assert_includes message, "wss://vroxy.example"
  end
end
