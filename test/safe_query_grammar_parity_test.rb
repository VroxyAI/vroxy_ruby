# frozen_string_literal: true

require "test_helper"

class SafeQueryGrammarParityTest < Minitest::Test
  Runner = Vroxy::SafeQuery::Runner
  Config = Vroxy::SafeQuery::Config

  SERVER_SCOPE_STEPS = %w[where where_not order limit offset group].freeze
  SERVER_TERMINALS   = %w[count sum average minimum maximum pluck first last to_a exists?].freeze
  SERVER_COMPARISON_SUFFIXES = %w[gt gte lt lte].freeze
  SERVER_RELATIVE_UNITS = %w[second minute hour day week month year].freeze
  SERVER_DEFAULT_LIMIT = 50
  SERVER_MAX_LIMIT     = 200
  SERVER_MAX_OFFSET    = 100_000

  def test_scope_steps_match_the_server_grammar
    assert_equal SERVER_SCOPE_STEPS, Runner::SCOPE_STEPS
  end

  def test_terminals_match_the_server_grammar
    assert_equal SERVER_TERMINALS, Runner::TERMINALS
  end

  def test_comparison_suffixes_match_the_server_grammar
    SERVER_COMPARISON_SUFFIXES.each do |suffix|
      assert_match Runner::COMPARISON_RE, "amount_#{suffix}", suffix
    end
    refute_match Runner::COMPARISON_RE, "amount_ne"
    refute_match Runner::COMPARISON_RE, "amount_like"
  end

  def test_relative_time_units_match_the_server_grammar
    assert_equal SERVER_RELATIVE_UNITS.sort, Runner::DURATION_UNITS.keys.sort

    SERVER_RELATIVE_UNITS.each do |unit|
      %w[ago from_now].each do |direction|
        [ "1.#{unit}.#{direction}", "7.#{unit}s.#{direction}" ].each do |literal|
          assert_match Runner::REL_TIME_RE, literal, literal
        end
      end
    end
  end

  def test_a_relative_time_lookalike_is_not_in_the_grammar
    [ "7.fortnights.ago", "7.days.system", "7.days.ago.tap", "days.ago", "-1.days.ago" ].each do |literal|
      refute_match Runner::REL_TIME_RE, literal, literal
    end
  end

  def test_default_and_hard_row_caps_match_the_server_defaults
    assert_equal SERVER_DEFAULT_LIMIT, Config::DEFAULT_ROWS
    assert_equal SERVER_MAX_LIMIT, Config::DEFAULT_MAX_ROWS
    assert_equal SERVER_MAX_OFFSET, Runner::MAX_OFFSET
  end

  def test_a_fresh_config_starts_at_the_server_caps
    config = Config.new
    assert_equal SERVER_DEFAULT_LIMIT, config.default_rows
    assert_equal SERVER_MAX_LIMIT, config.max_rows
  end

  def test_the_string_truncation_matches_the_server
    assert_equal 500, Runner::MAX_STRING_CHARS
  end

  def test_the_secret_column_pattern_matches_the_server
    server_pattern = /password|secret|credential|api_key|(\A|_)token(\z|_)|_key\z|_digest\z|\Adigest\z/i
    assert_equal server_pattern.source, Vroxy::SafeQuery::SECRET_COLUMN_RE.source
  end

  def test_the_result_envelope_matches_the_server
    assert_equal({ "ok" => false, "error" => "boom" }, Runner.err("boom"))
    assert_equal({ "ok" => false, "error" => "boom", "sql" => "SELECT 1" }, Runner.err("boom", sql: "SELECT 1"))
  end
end
