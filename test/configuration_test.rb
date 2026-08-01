# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def test_defaults
    config = Ctovibe.configuration
    assert_equal "https://ctovibe.ai", config.endpoint
    assert config.auto_inject
    assert_empty config.exclude_paths
    assert_nil config.identify
  end

  def test_enabled_derives_from_api_key
    refute Ctovibe.configuration.enabled?, "empty api_key should be disabled"

    Ctovibe.configure { |c| c.api_key = "pk_test" }
    assert Ctovibe.configuration.enabled?
  end

  def test_enabled_flag_wins_over_derivation
    Ctovibe.configure do |c|
      c.api_key = "pk_test"
      c.enabled = false
    end
    refute Ctovibe.configuration.enabled?
  end

  def test_excluded_matches_string_and_regexp
    Ctovibe.configure do |c|
      c.exclude_paths = ["/up", %r{\A/admin}]
    end
    config = Ctovibe.configuration
    assert config.excluded?("/up")
    assert config.excluded?("/admin/dashboard")
    refute config.excluded?("/pricing")
  end
end
