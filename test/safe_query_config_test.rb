# frozen_string_literal: true

require "test_helper"

class SafeQueryConfigTest < Minitest::Test
  ConfigurationError = Vroxy::SafeQuery::ConfigurationError

  def config
    Vroxy.configuration.safe_query
  end

  def long_secret
    "qs_#{'a' * 40}"
  end

  def test_nothing_is_queryable_by_default
    assert_empty config.model_names
    refute config.configured?
    refute config.enabled?
  end

  def test_a_secret_alone_does_not_enable_it
    config.secret = long_secret
    refute config.enabled?
  end

  def test_a_declared_model_alone_does_not_enable_it
    config.model "Deal", columns: %w[id]
    refute config.enabled?
  end

  def test_secret_plus_a_model_enables_it
    config.secret = long_secret
    config.model "Deal", columns: %w[id]
    assert config.enabled?
  end

  def test_forcing_enabled_true_cannot_serve_an_unconfigured_surface
    config.enabled = true
    refute config.enabled?, "enabled=true with no secret and no models must not open the endpoint"
  end

  def test_forcing_enabled_false_always_disables
    config.secret = long_secret
    config.model "Deal", columns: %w[id]
    config.enabled = false
    refute config.enabled?
  end

  def test_a_short_secret_is_refused
    error = assert_raises(ConfigurationError) { config.secret = "too-short" }
    assert_match(/at least 32 characters/, error.message)
  end

  def test_a_blank_secret_clears_rather_than_raising
    config.secret = long_secret
    config.secret = ""
    assert_nil config.secret
  end

  def test_a_credential_column_is_refused_at_declaration
    %w[api_key password password_digest access_token session_secret encryption_key credentials].each do |column|
      error = assert_raises(ConfigurationError, column) do
        config.model "Account", columns: [ "id", column ]
      end
      assert_match(/reads as a credential/, error.message)
    end
  end

  def test_a_non_identifier_column_is_refused_at_declaration
    [ "id) OR 1=1 --", "amount; DROP TABLE deals", "(SELECT 1)", "a b", "" ].each do |column|
      assert_raises(ConfigurationError, column) do
        config.model "Deal", columns: [ column ]
      end
    end
  end

  def test_a_model_needs_at_least_one_column
    assert_raises(ConfigurationError) { config.model "Deal", columns: [] }
  end

  def test_a_non_constant_model_name_is_refused
    [ "deal", "Deal;DROP", "Deal.where", "1Deal", "" ].each do |name|
      assert_raises(ConfigurationError, name) { config.model name, columns: %w[id] }
    end
  end

  def test_a_scope_must_be_callable
    assert_raises(ConfigurationError) { config.model "Deal", columns: %w[id], scope: "where(archived: false)" }
  end

  def test_redeclaring_a_model_replaces_it
    config.model "Deal", columns: %w[id]
    config.model "Deal", columns: %w[id status]
    assert_equal 1, config.model_names.length
    assert_equal %w[id status], config.rule_for("Deal").columns
  end

  def test_max_rows_is_clamped_to_the_absolute_ceiling
    config.max_rows = 1_000_000
    assert_equal Vroxy::SafeQuery::Config::ABSOLUTE_MAX_ROWS, config.max_rows
  end

  def test_max_rows_cannot_go_below_one
    config.max_rows = 0
    assert_equal 1, config.max_rows
  end

  def test_lowering_max_rows_drags_default_rows_down_with_it
    config.max_rows = 5
    assert_equal 5, config.default_rows
  end

  def test_default_rows_cannot_exceed_max_rows
    config.max_rows     = 10
    config.default_rows = 500
    assert_equal 10, config.default_rows
  end

  def test_timestamp_tolerance_is_clamped
    config.timestamp_tolerance = 86_400
    assert_equal Vroxy::SafeQuery::Config::MAX_TOLERANCE, config.timestamp_tolerance
  end

  def test_path_must_be_a_path
    [ "vroxy/query", "https://evil.test/x", "/vroxy query", "" ].each do |path|
      assert_raises(ConfigurationError, path) { config.path = path }
    end
  end

  def test_path_accepts_a_normal_path
    config.path = "/internal/vroxy/query/"
    assert_equal "/internal/vroxy/query", config.path
  end

  def test_a_per_model_row_cap_never_exceeds_the_global_one
    config.max_rows = 10
    rule = config.model "Deal", columns: %w[id], max_rows: 500
    assert_equal 10, config.max_rows_for(rule)
  end

  def test_describe_never_names_an_undeclared_column
    config.model "Account", columns: %w[id name]
    described = config.describe["models"].first
    assert_equal "Account", described["name"]
    assert_equal %w[id name], described["columns"]
    refute described["scoped"]
  end

  def test_describe_reports_the_scoped_flag
    config.model "Deal", columns: %w[id], scope: ->(rel) { rel }
    assert config.describe["models"].first["scoped"]
  end
end
