# frozen_string_literal: true

require "fileutils"
require "active_record"

module SafeQueryFixtures
  DB_PATH = File.expand_path("../../tmp/safe_query_test.sqlite3", __dir__)
  DEFAULT_ADAPTER = "sqlite3"
  DEFAULT_POSTGRES_URL = "postgres://vroxy_test:vroxy_test@127.0.0.1:55432/vroxy_gem_test"

  module_function

  def adapter
    name = ENV.fetch("VROXY_TEST_ADAPTER", DEFAULT_ADAPTER).to_s
    name = "postgresql" if name == "postgres" || name == "pg"
    name
  end

  def postgresql?
    adapter == "postgresql"
  end

  def connection_spec
    return { adapter: "sqlite3", database: DB_PATH } unless postgresql?

    ENV.fetch("VROXY_TEST_DATABASE_URL", DEFAULT_POSTGRES_URL)
  end

  def connect!
    return if @connected

    unless postgresql?
      FileUtils.mkdir_p(File.dirname(DB_PATH))
      FileUtils.rm_f(DB_PATH)
    end

    ActiveRecord::Base.logger = nil
    ActiveRecord::Base.establish_connection(connection_spec)
    build_schema!
    define_models!
    @connected = true
  end

  def build_schema!
    connection = ActiveRecord::Base.connection
    connection.create_table(:deals, force: true) do |t|
      t.integer  :account_id
      t.string   :status
      t.integer  :amount
      t.integer  :small_amount, limit: 4
      t.boolean  :archived, default: false
      t.string   :secret_note
      t.datetime :created_at
    end

    connection.create_table(:accounts, force: true) do |t|
      t.string   :name
      t.string   :plan
      t.string   :api_key
      t.datetime :created_at
    end

    connection.create_table(:ledgers, force: true) do |t|
      t.string :note
    end

    connection.create_table(:shop_orders, force: true) do |t|
      t.string  :reference
      t.integer :total
    end
  end

  def define_models!
    Object.const_set(:Deal, Class.new(ActiveRecord::Base)) unless Object.const_defined?(:Deal)
    Object.const_set(:Account, Class.new(ActiveRecord::Base)) unless Object.const_defined?(:Account)
    Object.const_set(:Ledger, Class.new(ActiveRecord::Base)) unless Object.const_defined?(:Ledger)
    Object.const_set(:PlainRuby, Class.new) unless Object.const_defined?(:PlainRuby)

    unless Object.const_defined?(:Shop)
      shop = Module.new
      Object.const_set(:Shop, shop)
      order = Class.new(ActiveRecord::Base) { self.table_name = "shop_orders" }
      shop.const_set(:Order, order)
    end
  end

  def reseed!
    connect!
    Deal.delete_all
    Account.delete_all
    Ledger.delete_all
    Shop::Order.delete_all

    now = Time.now.utc

    Account.insert_all!([
      { id: 1, name: "Northwind",  plan: "pro",  api_key: "not-a-real-key-aaa", created_at: now - 86_400 },
      { id: 2, name: "Acme",      plan: "free", api_key: "not-a-real-key-bbb", created_at: now - 172_800 }
    ])

    rows = []
    rows << { id: 1, account_id: 1, status: "won",  amount: 500, archived: false,
              secret_note: "internal", created_at: now - 3_600 }
    rows << { id: 2, account_id: 1, status: "open", amount: 250, archived: false,
              secret_note: "internal", created_at: now - 7_200 }
    rows << { id: 3, account_id: 2, status: "open", amount: 100, archived: false,
              secret_note: "internal", created_at: now - (86_400 * 30) }
    rows << { id: 4, account_id: 2, status: "lost", amount: 999, archived: true,
              secret_note: "hidden", created_at: now - 60 }
    (5..40).each do |i|
      rows << { id: i, account_id: 1, status: "open", amount: i, archived: false,
                secret_note: "internal", created_at: now - (i * 60) }
    end
    Deal.insert_all!(rows)

    Shop::Order.insert_all!([ { id: 1, reference: "SO-1", total: 10 } ])
  end

  def declare_default_allowlist!(config)
    config.model "Deal",
                 columns: %w[id account_id status amount archived created_at],
                 scope: ->(rel) { rel.where(archived: false) }
    config.model "Account", columns: %w[id name plan created_at]
  end
end
