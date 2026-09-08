# frozen_string_literal: true

require "test_helper"
require "json"
require "time"
require "support/safe_query_fixtures"

class SafeQueryVectorsTest < Minitest::Test
  VECTORS = JSON.parse(File.read(File.expand_path("vectors/safe_query_vectors.json", __dir__))).freeze

  class << self
    attr_accessor :prepared
  end

  def setup
    super
    prepare_database!
    declare_allowlist!
  end

  VECTORS["cases"].each_with_index do |vector, index|
    define_method(:"test_vector_#{index}_#{vector['name'].gsub(/[^a-z0-9]+/i, '_').downcase}") do
      result = Vroxy::SafeQuery::Runner.execute(vector["payload"])
      expected = vector["expect"]

      assert_equal expected["ok"], result["ok"],
                   "#{vector['name']}: expected ok=#{expected['ok']}, got #{result.inspect}"

      if expected.key?("result")
        assert_equal expected["result"], result["result"], vector["name"]
      end

      if expected["error_matches"]
        assert_match(/#{Regexp.escape(expected['error_matches'])}/, result["error"].to_s, vector["name"])
      end
    end
  end

  def test_the_fixture_matches_the_declared_schema
    VECTORS["fixture"]["tables"].each do |table|
      klass = Object.const_get(table["model"])
      assert_equal table["columns"].map { |c| c["name"] }.sort, klass.column_names.sort, table["name"]
      assert_equal table["rows"].length, klass.count, table["name"]
    end
  end

  def test_every_case_asserts_something
    VECTORS["cases"].each do |vector|
      expect = vector["expect"]
      assert expect.key?("result") || expect.key?("error_matches"),
             "#{vector['name']} asserts only ok/not-ok — pin the result or the error"
    end
  end

  private

  def prepare_database!
    return if self.class.prepared

    SafeQueryFixtures.connect!
    connection = ActiveRecord::Base.connection

    VECTORS["fixture"]["tables"].each do |table|
      connection.create_table(table["name"], force: true, id: false) do |t|
        table["columns"].each do |column|
          t.column column["name"], column["type"].to_sym,
                   primary_key: column["name"] == "id"
        end
      end

      klass = Class.new(ActiveRecord::Base) do
        self.table_name  = table["name"]
        self.primary_key = "id"
      end
      Object.send(:remove_const, table["model"]) if Object.const_defined?(table["model"], false)
      Object.const_set(table["model"], klass)

      table["rows"].each { |row| klass.create!(cast_row(row)) }
    end

    self.class.prepared = true
  end

  def cast_row(row)
    row.each_with_object({}) do |(key, value), out|
      out[key] = value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T/) ? Time.parse(value).utc : value
    end
  end

  def declare_allowlist!
    config = Vroxy.configuration.safe_query
    config.secret = "vector-secret-" + ("v" * 32)
    config.max_rows     = VECTORS["settings"]["max_rows"]
    config.default_rows = VECTORS["settings"]["default_rows"]

    VECTORS["allowlist"].each do |entry|
      scope = build_scope(entry["scope"])
      config.model entry["model"], columns: entry["columns"], scope: scope
    end
  end

  def build_scope(spec)
    return nil unless spec

    conditions = spec.fetch("where")
    ->(relation) { relation.where(conditions) }
  end
end
