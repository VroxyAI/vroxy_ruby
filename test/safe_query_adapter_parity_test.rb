# frozen_string_literal: true

require "test_helper"
require "support/safe_query_fixtures"

class SafeQueryAdapterParityTest < Minitest::Test
  def setup
    super
    SafeQueryFixtures.reseed!
    @config = Vroxy.configuration.safe_query
    @config.secret = "qs_#{'a' * 40}"
    @config.model "Deal",
                  columns: %w[id account_id status amount small_amount archived created_at],
                  scope: ->(relation) { relation.where(archived: false) }
  end

  def run_query(payload)
    Vroxy::SafeQuery::Runner.execute(payload, config: @config)
  end

  def where_count(column, value)
    run_query({ "model" => "Deal", "scope" => [ { "where" => { column => value } } ], "terminal" => "count" })
  end

  def test_the_adapter_under_test_is_the_one_the_environment_asked_for
    expected = SafeQueryFixtures.postgresql? ? "PostgreSQL" : "SQLite"
    assert_equal expected, ActiveRecord::Base.connection.adapter_name
  end

  def test_a_nul_byte_in_a_value_is_refused_the_same_way_on_every_adapter
    result = where_count("status", "won\u0000")
    refute result["ok"], "a NUL byte must never reach the adapter: #{result.inspect}"
    assert_match(/NUL byte/, result["error"])
    assert_equal 40, Deal.count
  end

  def test_a_nul_byte_is_refused_inside_an_array_and_behind_a_comparison
    array = where_count("status", [ "won", "lost\u0000" ])
    refute array["ok"]
    assert_match(/NUL byte/, array["error"])

    comparison = where_count("status_gt", "a\u0000")
    refute comparison["ok"]
    assert_match(/NUL byte/, comparison["error"])
  end

  def test_sum_and_average_refuse_a_non_numeric_column_on_every_adapter
    %w[sum average].each do |terminal|
      %w[status created_at archived].each do |column|
        result = run_query({ "model" => "Deal", "terminal" => terminal, "terminal_args" => [ column ] })
        refute result["ok"], "#{terminal}(#{column}) must not invent a number: #{result.inspect}"
        assert_match(/needs a numeric column/, result["error"], "#{terminal}(#{column})")
      end
    end
  end

  def test_sum_and_average_still_answer_on_a_numeric_column
    assert_equal 1_660, run_query({ "model" => "Deal", "terminal" => "sum",
                                    "terminal_args" => %w[amount] })["result"]
    average = run_query({ "model" => "Deal", "terminal" => "average", "terminal_args" => %w[amount] })
    assert average["ok"], average["error"].to_s
    assert_in_delta 1_660.0 / 39, average["result"], 0.001
  end

  def test_minimum_and_maximum_still_answer_on_a_non_numeric_column
    %w[minimum maximum].each do |terminal|
      result = run_query({ "model" => "Deal", "terminal" => terminal, "terminal_args" => %w[status] })
      assert result["ok"], "#{terminal}: #{result['error']}"
      assert_includes %w[open won], result["result"]
    end
  end

  def test_a_value_too_wide_for_the_column_is_refused_for_the_real_reason
    result = where_count("small_amount", 2**31)
    refute result["ok"], result.inspect
    assert_match(/out of range/, result["error"])
    refute_match(/would match NULL/, result["error"])
  end

  def test_the_widest_value_the_column_can_hold_is_not_a_range_refusal
    result = where_count("small_amount", 2**31 - 1)
    assert result["ok"], result["error"].to_s
    assert_equal 0, result["result"]
  end

  def test_an_out_of_range_value_behind_a_comparison_is_refused_too
    result = where_count("small_amount_gte", 2**31)
    refute result["ok"], result.inspect
    assert_match(/out of range/, result["error"])
  end

  def test_a_value_the_column_cannot_represent_still_says_it_would_match_null
    result = where_count("amount", "lots")
    refute result["ok"]
    assert_match(/would match NULL/, result["error"])
    refute_match(/out of range/, result["error"])
  end

  def test_an_injection_payload_stays_one_quoted_literal_on_every_adapter
    result = where_count("status", "'; DROP TABLE deals; --")
    assert result["ok"], result["error"].to_s
    assert_equal 0, result["result"]
    assert_includes result["sql"], "'''; DROP TABLE deals; --'"
    assert_equal 40, Deal.count
  end

  def test_the_row_cap_renders_the_same_limit_and_offset_on_every_adapter
    result = run_query({ "model" => "Deal", "scope" => [ { "offset" => 10**12 } ],
                         "terminal" => "pluck", "terminal_args" => %w[id] })
    assert result["ok"], result["error"].to_s
    assert_includes result["sql"], "LIMIT 50"
    assert_includes result["sql"], "OFFSET 100000"
  end

  def test_a_shaped_row_serializes_the_same_scalars_on_every_adapter
    row = run_query({ "model" => "Deal", "scope" => [ { "where" => { "id" => 1 } } ],
                      "terminal" => "to_a" })["result"].first
    assert_equal 1, row["id"]
    assert_equal "won", row["status"]
    assert_equal 500, row["amount"]
    assert_equal false, row["archived"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, row["created_at"])
    assert_nil row["small_amount"]
  end

  def test_a_relative_time_bound_splits_the_rows_the_same_way_on_every_adapter
    recent = where_count("created_at_gte", "1.hour.ago")
    older  = where_count("created_at_lte", "1.hour.ago")
    assert recent["ok"]
    assert older["ok"]
    assert_equal 39, recent["result"] + older["result"]
  end

  def test_a_grouped_count_comes_back_keyed_the_same_way_on_every_adapter
    result = run_query({ "model" => "Deal", "scope" => [ { "group" => "status" } ], "terminal" => "count" })
    assert result["ok"], result["error"].to_s
    assert_equal({ "open" => 38, "won" => 1 }, result["result"])
  end
end
