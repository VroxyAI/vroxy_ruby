# frozen_string_literal: true

require "test_helper"
require "support/safe_query_fixtures"

class SafeQueryRunnerTest < Minitest::Test
  def setup
    super
    SafeQueryFixtures.reseed!
    @config = Vroxy.configuration.safe_query
    @config.secret = "qs_#{'a' * 40}"
    SafeQueryFixtures.declare_default_allowlist!(@config)
  end

  def run_query(payload)
    Vroxy::SafeQuery::Runner.execute(payload, config: @config)
  end

  def assert_refused(payload, pattern)
    result = run_query(payload)
    refute result["ok"], "expected a refusal, got #{result.inspect}"
    assert_match pattern, result["error"]
    result
  end

  def test_a_plain_count_answers_the_business_question
    result = run_query({ "model" => "Deal", "terminal" => "count" })
    assert result["ok"]
    assert_equal 39, result["result"]
    assert_includes result["sql"], "SELECT"
  end

  def test_the_sql_that_ran_comes_back
    result = run_query({ "model" => "Deal", "scope" => [ { "where" => { "status" => "won" } } ],
                         "terminal" => "count" })
    assert_includes result["sql"], "archived"
    assert_includes result["sql"], "status"
  end

  def test_an_undeclared_model_is_refused
    assert_refused({ "model" => "Ledger", "terminal" => "count" }, /not exposed to vroxy/)
  end

  def test_a_namespaced_model_is_queryable_only_once_declared
    assert_refused({ "model" => "Shop::Order", "terminal" => "count" }, /not exposed to vroxy/)

    @config.model "Shop::Order", columns: %w[id reference total]
    result = run_query({ "model" => "Shop::Order", "terminal" => "count" })
    assert result["ok"]
    assert_equal 1, result["result"]
  end

  def test_a_declared_constant_that_is_not_a_model_is_refused
    @config.model "PlainRuby", columns: %w[id]
    assert_refused({ "model" => "PlainRuby", "terminal" => "count" }, /not an ActiveRecord model/)
  end

  def test_a_declared_model_that_does_not_exist_is_refused
    @config.model "NoSuchModel", columns: %w[id]
    assert_refused({ "model" => "NoSuchModel", "terminal" => "count" }, /not defined in this application/)
  end

  def test_an_undeclared_column_is_refused_in_where
    assert_refused({ "model" => "Deal", "scope" => [ { "where" => { "secret_note" => "hidden" } } ],
                     "terminal" => "count" }, /where column "secret_note"/)
  end

  def test_an_undeclared_column_is_refused_in_where_not
    assert_refused({ "model" => "Deal", "scope" => [ { "where_not" => { "secret_note" => "hidden" } } ],
                     "terminal" => "count" }, /where_not column "secret_note"/)
  end

  def test_an_undeclared_column_is_refused_in_order
    assert_refused({ "model" => "Deal", "scope" => [ { "order" => "secret_note desc" } ],
                     "terminal" => "count" }, /order column "secret_note"/)
    assert_refused({ "model" => "Deal", "scope" => [ { "order" => { "secret_note" => "desc" } } ],
                     "terminal" => "count" }, /order column "secret_note"/)
  end

  def test_an_undeclared_column_is_refused_in_group
    assert_refused({ "model" => "Deal", "scope" => [ { "group" => "secret_note" } ],
                     "terminal" => "count" }, /group column "secret_note"/)
    assert_refused({ "model" => "Deal", "scope" => [ { "group" => %w[status secret_note] } ],
                     "terminal" => "count" }, /group column "secret_note"/)
  end

  def test_an_undeclared_column_is_refused_in_pluck
    assert_refused({ "model" => "Deal", "terminal" => "pluck", "terminal_args" => %w[secret_note] },
                   /pluck column "secret_note"/)
    assert_refused({ "model" => "Deal", "terminal" => "pluck", "terminal_args" => %w[id secret_note] },
                   /pluck column "secret_note"/)
  end

  def test_an_undeclared_column_is_refused_in_every_numeric_terminal
    %w[sum average minimum maximum].each do |terminal|
      assert_refused({ "model" => "Deal", "terminal" => terminal, "terminal_args" => %w[secret_note] },
                     /#{terminal} column "secret_note"/)
    end
  end

  def test_an_undeclared_column_is_refused_behind_a_comparison_suffix
    assert_refused({ "model" => "Deal", "scope" => [ { "where" => { "secret_note_gt" => "a" } } ],
                     "terminal" => "count" }, /not an allowed column/)
  end

  def test_a_credential_column_stays_invisible_even_when_it_exists
    assert_refused({ "model" => "Account", "scope" => [ { "where" => { "api_key" => "not-a-real-key-aaa" } } ],
                     "terminal" => "count" }, /not an allowed column/)
    assert_refused({ "model" => "Account", "terminal" => "pluck", "terminal_args" => %w[api_key] },
                   /not an allowed column/)
  end

  def test_a_declared_column_that_the_table_does_not_have_is_refused
    @config.model "Ledger", columns: %w[id note phantom]
    assert_refused({ "model" => "Ledger", "scope" => [ { "where" => { "phantom" => 1 } } ],
                     "terminal" => "count" }, /not an allowed column/)
  end

  def test_another_models_column_is_refused
    assert_refused({ "model" => "Deal", "scope" => [ { "where" => { "plan" => "pro" } } ],
                     "terminal" => "count" }, /not an allowed column/)
  end

  def test_shaped_rows_never_carry_an_undeclared_column
    result = run_query({ "model" => "Deal", "scope" => [ { "where" => { "id" => 1 } } ], "terminal" => "to_a" })
    assert result["ok"]
    assert_equal 1, result["result"].length
    refute result["result"].first.key?("secret_note")
    assert_equal @config.rule_for("Deal").columns.sort, result["result"].first.keys.sort
  end

  def test_shaped_rows_from_first_and_last_are_narrowed_too
    %w[first last].each do |terminal|
      row = run_query({ "model" => "Deal", "terminal" => terminal })["result"]
      refute row.key?("secret_note"), terminal
    end
  end

  def test_every_write_terminal_is_refused
    %w[delete_all destroy_all update_all update insert insert_all create create! touch_all
       find_by_sql exec_query connection unscope none].each do |terminal|
      assert_refused({ "model" => "Deal", "terminal" => terminal }, /not allowed/)
    end
  end

  def test_every_non_grammar_scope_step_is_refused
    %w[unscope or rewhere except only joins includes from lock select distinct find_by_sql
       delete_all destroy_all update_all].each do |step|
      assert_refused({ "model" => "Deal", "scope" => [ { step => "anything" } ], "terminal" => "count" },
                     /not allowed/)
    end
  end

  def test_a_sql_fragment_as_a_column_name_is_refused
    [ "id) OR 1=1 --", "id; DROP TABLE deals", "(SELECT api_key FROM accounts LIMIT 1)",
      "amount/**/", "id\nUNION SELECT 1" ].each do |column|
      assert_refused({ "model" => "Deal", "scope" => [ { "where" => { column => 1 } } ], "terminal" => "count" },
                     /not an allowed column/)
      assert_refused({ "model" => "Deal", "terminal" => "pluck", "terminal_args" => [ column ] },
                     /not an allowed column/)
      assert_refused({ "model" => "Deal", "scope" => [ { "group" => column } ], "terminal" => "count" },
                     /not an allowed column/)
    end
  end

  def test_a_sql_fragment_in_an_order_direction_is_refused
    assert_refused({ "model" => "Deal", "scope" => [ { "order" => "id desc; DROP TABLE deals" } ],
                     "terminal" => "count" }, /`order` direction .* not allowed\. Allowed: asc, desc/)
    assert_refused({ "model" => "Deal", "scope" => [ { "order" => { "id" => "asc, secret_note desc" } } ],
                     "terminal" => "count" }, /`order` direction .* not allowed\. Allowed: asc, desc/)
  end

  def test_sql_injection_in_a_value_stays_a_quoted_literal
    payload = "'; DROP TABLE deals; --"
    result  = run_query({ "model" => "Deal", "scope" => [ { "where" => { "status" => payload } } ],
                          "terminal" => "count" })
    assert result["ok"]
    assert_equal 0, result["result"]
    assert_equal 40, Deal.count, "the table must still be there with every row"
    assert_includes result["sql"], "'''; DROP TABLE deals; --'",
                    "the payload must appear as one escaped literal, not as SQL"
  end

  def test_sql_injection_through_a_comparison_value_is_quoted
    result = run_query({ "model" => "Deal",
                         "scope" => [ { "where" => { "status_gt" => "a' OR '1'='1" } } ],
                         "terminal" => "count" })
    assert result["ok"]
    assert_equal 40, Deal.count
  end

  def test_a_nested_value_is_not_a_supported_primitive
    [ { "in" => [ 1 ] }, [ { "a" => 1 } ], Object.new ].each do |value|
      assert_refused({ "model" => "Deal", "scope" => [ { "where" => { "status" => value } } ],
                       "terminal" => "count" }, /not a supported primitive/)
    end
  end

  def test_a_step_must_be_a_single_key_hash
    [ { "where" => { "id" => 1 }, "limit" => 1 }, {}, "where", [ "where" ], nil ].each do |step|
      assert_refused({ "model" => "Deal", "scope" => [ step ], "terminal" => "count" }, /exactly one key/)
    end
  end

  def test_too_many_steps_are_refused
    steps = Array.new(Vroxy::SafeQuery::Config::MAX_STEPS + 1) { { "where" => { "archived" => false } } }
    assert_refused({ "model" => "Deal", "scope" => steps, "terminal" => "count" }, /at most/)
  end

  def test_the_declared_scope_cannot_be_escaped_by_any_step_combination
    escapes = [
      [ { "where" => { "archived" => true } } ],
      [ { "where_not" => { "archived" => false } } ],
      [ { "where" => { "id" => 4 } } ],
      [ { "where" => { "secret_note" => "hidden" } } ],
      [ { "where" => { "archived" => true } }, { "where" => { "archived" => false } } ],
      [ { "order" => "id desc" }, { "limit" => 200 } ],
      [ { "offset" => 0 }, { "limit" => 200 }, { "order" => "amount desc" } ],
      [ { "where" => { "amount_gte" => 999 } } ],
      [ { "where" => { "status" => %w[lost won open] } } ]
    ]

    executed = 0
    escapes.each do |steps|
      result = run_query({ "model" => "Deal", "scope" => steps, "terminal" => "pluck", "terminal_args" => %w[id] })
      next unless result["ok"]

      executed += 1
      refute_includes result["result"], 4, "the archived deal escaped the scope via #{steps.inspect}"
    end

    assert_operator executed, :>=, escapes.length - 1,
                    "these combinations must actually RUN, not be refused before the scope matters"
  end

  def test_the_declared_scope_hides_the_row_from_every_terminal
    hidden = 4
    assert_equal 39, run_query({ "model" => "Deal", "terminal" => "count" })["result"]
    refute run_query({ "model" => "Deal", "scope" => [ { "where" => { "id" => hidden } } ],
                       "terminal" => "exists?" })["result"]
    assert_equal 999, Deal.find(hidden).amount
    refute_equal 999, run_query({ "model" => "Deal", "terminal" => "maximum",
                                  "terminal_args" => %w[amount] })["result"]
  end

  def test_a_scope_returning_a_foreign_relation_is_refused
    @config.model "Deal", columns: %w[id], scope: ->(_rel) { Account.all }
    assert_refused({ "model" => "Deal", "terminal" => "count" }, /must return an ActiveRecord::Relation of Deal/)
  end

  def test_a_scope_returning_a_plain_array_is_refused
    @config.model "Deal", columns: %w[id], scope: ->(rel) { rel.to_a }
    assert_refused({ "model" => "Deal", "terminal" => "count" }, /must return an ActiveRecord::Relation/)
  end

  def test_a_scope_returning_an_unscoped_relation_still_governs_its_own_reach
    @config.model "Deal", columns: %w[id archived], scope: ->(_rel) { Deal.unscoped.where(id: 1) }
    result = run_query({ "model" => "Deal", "terminal" => "pluck", "terminal_args" => %w[id] })
    assert_equal [ 1 ], result["result"]
  end

  def test_the_row_cap_holds_when_the_caller_asks_for_more
    @config.max_rows     = 5
    @config.default_rows = 3

    capped = run_query({ "model" => "Deal", "scope" => [ { "limit" => 10_000 } ],
                         "terminal" => "pluck", "terminal_args" => %w[id] })
    assert_equal 5, capped["result"].length

    defaulted = run_query({ "model" => "Deal", "terminal" => "pluck", "terminal_args" => %w[id] })
    assert_equal 3, defaulted["result"].length

    rows = run_query({ "model" => "Deal", "terminal" => "to_a" })
    assert_equal 3, rows["result"].length
  end

  def test_a_negative_or_zero_limit_becomes_one_row
    @config.max_rows = 5
    [ 0, -1, -10_000 ].each do |limit|
      result = run_query({ "model" => "Deal", "scope" => [ { "limit" => limit } ],
                           "terminal" => "pluck", "terminal_args" => %w[id] })
      assert_equal 1, result["result"].length, limit.to_s
    end
  end

  def test_a_grouped_terminal_is_row_capped_too
    @config.max_rows     = 2
    @config.default_rows = 2
    result = run_query({ "model" => "Deal", "scope" => [ { "group" => "amount" } ], "terminal" => "count" })
    assert result["ok"]
    assert_operator result["result"].length, :<=, 2
  end

  def test_an_ungrouped_count_is_never_capped_so_totals_stay_true
    @config.max_rows     = 2
    @config.default_rows = 2
    assert_equal 39, run_query({ "model" => "Deal", "terminal" => "count" })["result"]
    assert_equal 1_660, run_query({ "model" => "Deal", "terminal" => "sum",
                                    "terminal_args" => %w[amount] })["result"]
  end

  def test_the_offset_is_bounded
    result = run_query({ "model" => "Deal", "scope" => [ { "offset" => 10**12 } ],
                         "terminal" => "pluck", "terminal_args" => %w[id] })
    assert result["ok"]
    assert_includes result["sql"], "OFFSET 100000"
  end

  def test_a_non_integer_limit_is_refused
    assert_refused({ "model" => "Deal", "scope" => [ { "limit" => "10; DROP TABLE deals" } ],
                     "terminal" => "count" }, /expected an integer/)
    assert_equal 40, Deal.count
  end

  def test_nothing_a_query_touches_persists
    @config.model "Ledger", columns: %w[id note],
                            scope: lambda { |rel|
                              Ledger.create!(note: "written from inside a safe query")
                              rel
                            }

    assert_equal 0, Ledger.count
    result = run_query({ "model" => "Ledger", "terminal" => "count" })
    assert result["ok"]
    assert_equal 1, result["result"], "the write is visible INSIDE the transaction"
    assert_equal 0, Ledger.count, "the transaction must roll back — nothing may persist"
  end

  def test_a_model_callback_that_writes_is_rolled_back_too
    fired = 0
    Deal.after_find do
      fired += 1
      Ledger.create!(note: "callback write")
    end

    result = run_query({ "model" => "Deal", "scope" => [ { "limit" => 2 } ], "terminal" => "to_a" })
    assert result["ok"]
    assert_operator fired, :>, 0, "the callback has to actually run for this to prove anything"
    assert_equal 0, Ledger.count, "an after_find write must not survive the query"
  ensure
    Deal.reset_callbacks(:find)
  end

  def test_a_value_the_column_cannot_represent_is_refused
    result = assert_refused({ "model" => "Deal", "scope" => [ { "where" => { "amount" => "lots" } } ],
                              "terminal" => "count" }, /would match NULL/)
    assert_match(/integer column/, result["error"])
  end

  def test_relative_times_resolve
    recent = run_query({ "model" => "Deal", "scope" => [ { "where" => { "created_at_gte" => "1.hour.ago" } } ],
                         "terminal" => "count" })
    assert recent["ok"]
    older = run_query({ "model" => "Deal", "scope" => [ { "where" => { "created_at_lte" => "1.hour.ago" } } ],
                        "terminal" => "count" })
    assert older["ok"]
    assert_equal 39, recent["result"] + older["result"]
  end

  def test_a_relative_time_lookalike_is_not_dispatched
    [ "7.days.system", "7.days.ago; DROP TABLE deals", "0.exit.ago", "7.fortnights.ago" ].each do |value|
      result = run_query({ "model" => "Deal", "scope" => [ { "where" => { "status" => value } } ],
                           "terminal" => "count" })
      assert result["ok"], value
      assert_equal 0, result["result"], value
    end
    assert_equal 40, Deal.count
  end

  def test_a_payload_that_is_not_an_object_is_refused
    [ [], "count", 7, nil ].each do |payload|
      result = Vroxy::SafeQuery::Runner.execute(payload, config: @config)
      refute result["ok"], payload.inspect
    end
  end

  def test_symbol_keys_from_a_ruby_caller_are_accepted
    result = Vroxy::SafeQuery::Runner.execute(
      { model: "Deal", scope: [ { where: { status: "won" } } ], terminal: "count" }, config: @config
    )
    assert result["ok"]
    assert_equal 1, result["result"]
  end

  def test_long_strings_are_truncated_in_shaped_rows
    Account.create!(id: 3, name: "x" * 5_000, plan: "pro", created_at: Time.now.utc)
    row = run_query({ "model" => "Account", "scope" => [ { "where" => { "id" => 3 } } ],
                      "terminal" => "to_a" })["result"].first
    assert_equal 500, row["name"].length
  end

  def test_times_come_back_as_iso8601
    row = run_query({ "model" => "Deal", "scope" => [ { "where" => { "id" => 1 } } ],
                      "terminal" => "to_a" })["result"].first
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, row["created_at"])
  end
end
