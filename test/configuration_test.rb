# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def test_defaults
    config = Vroxy.configuration
    assert_equal "https://vroxy.ai", config.endpoint
    assert config.auto_inject
    assert_empty config.exclude_paths
    assert_nil config.identify
  end

  def test_enabled_derives_from_api_key
    refute Vroxy.configuration.enabled?, "empty api_key should be disabled"

    Vroxy.configure { |c| c.api_key = "pk_test" }
    assert Vroxy.configuration.enabled?
  end

  def test_enabled_flag_wins_over_derivation
    Vroxy.configure do |c|
      c.api_key = "pk_test"
      c.enabled = false
    end
    refute Vroxy.configuration.enabled?
  end

  def test_excluded_matches_string_and_regexp
    Vroxy.configure do |c|
      c.exclude_paths = ["/up", %r{\A/admin}]
    end
    config = Vroxy.configuration
    assert config.excluded?("/up")
    assert config.excluded?("/admin/dashboard")
    refute config.excluded?("/pricing")
  end

  def test_default_admin_roles
    assert_equal %w[admin owner], Vroxy.configuration.admin_roles
  end
end
