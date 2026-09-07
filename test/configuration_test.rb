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

  # Three call sites ask this question (inspector tag, signed access
  # level, render tracker).  When they compared differently, symbol
  # admin_roles enabled two of the three and the inspector booted
  # with a permanently empty partial trail.
  def test_admin_role_accepts_symbols_on_either_side
    Vroxy.configure { |c| c.admin_roles = [ :admin, :owner ] }
    config = Vroxy.configuration

    assert config.admin_role?("admin")
    assert config.admin_role?(:owner)
    refute config.admin_role?("member")
    refute config.admin_role?(nil)
  end

  def test_admin_role_with_string_roles
    Vroxy.configure { |c| c.admin_roles = %w[manager] }
    assert Vroxy.configuration.admin_role?(:manager)
    refute Vroxy.configuration.admin_role?("admin")
  end

  def test_production_falls_back_to_rack_env_without_rails
    original = ENV["RACK_ENV"]
    ENV["RACK_ENV"] = "production"
    assert Vroxy.production?

    Vroxy.configure { |c| c.api_key = "pk_1" }
    assert Vroxy.configuration.report_errors?, "auto mode should arm in a non-Rails production process"
  ensure
    ENV["RACK_ENV"] = original
  end

  def test_production_is_false_by_default
    refute Vroxy.production?
  end
end
