# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "active_support/cache"

class SafeQueryBootCheckTest < Minitest::Test
  BootCheck = Vroxy::SafeQuery::BootCheck

  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(message)
      @warnings << message
    end
  end

  class ExplodingLogger
    def warn(_message)
      raise "the logger is not up yet"
    end
  end

  class SharedStore
    def fresh?(_nonce, ttl:)
      true
    end
  end

  def setup
    super
    BootCheck.reset!
    @config = Vroxy.configuration.safe_query
    @config.secret = "qs_#{'b' * 40}"
    @config.model "Deal", columns: %w[id]
  end

  def teardown
    BootCheck.reset!
    super
  end

  def warning(env: "production", workers: nil)
    BootCheck.message_for(config: @config, env: env, workers: workers)
  end

  def test_the_default_in_process_store_warns_in_production
    text = warning
    refute_nil text
    assert_match(/safe_query replay defence is in-process/, text)
    assert_match(/nonce_store = Rails\.cache/, text)
  end

  def test_it_admits_it_cannot_count_the_processes_serving_the_endpoint
    text = warning
    assert_match(/cannot see how many others serve #{Regexp.escape(@config.path)}/, text)
    assert_match(/replica\/dyno count/, text)
    assert_match(/single_process = true/, text)
  end

  def test_a_known_worker_count_above_one_makes_the_warning_definite
    text = warning(workers: 4)
    assert_match(/configured for 4 web workers/, text)
    refute_match(/cannot see how many others/, text)
    refute_match(/single_process = true/, text)
  end

  def test_one_declared_worker_is_not_treated_as_proof_of_a_single_process
    text = warning(workers: 1)
    assert_match(/cannot see how many others/, text)
  end

  def test_the_freshness_window_in_the_warning_is_the_configured_one
    @config.timestamp_tolerance = 120
    assert_match(/120s freshness window/, warning)
  end

  def test_a_shared_store_is_silent
    @config.nonce_store = SharedStore.new
    assert_nil warning
  end

  def test_a_cache_store_that_is_itself_per_process_is_named_as_such
    @config.nonce_store = ActiveSupport::Cache::MemoryStore.new
    text = warning
    assert_match(/MemoryStore/, text)
    assert_match(/per-process/, text)
    assert_match(/assigning it did not make replay defence shared/, text)
  end

  def test_a_file_store_is_called_out_as_shared_between_workers_but_not_hosts
    Dir.mktmpdir do |dir|
      @config.nonce_store = ActiveSupport::Cache::FileStore.new(dir)
      text = warning
      assert_match(/FileStore/, text)
      assert_match(/not between hosts/, text)
    end
  end

  def test_a_nil_store_says_replay_defence_is_off_entirely
    @config.nonce_store = nil
    text = warning
    assert_match(/replay defence is OFF/, text)
  end

  def test_declaring_a_single_process_silences_the_in_process_warning
    @config.single_process = true
    assert_nil warning
    assert_nil warning(workers: 4)
  end

  def test_declaring_a_single_process_cannot_silence_a_missing_store
    @config.nonce_store = nil
    @config.single_process = true
    assert_match(/replay defence is OFF/, warning)
  end

  def test_development_and_test_stay_quiet
    %w[development test].each { |env| assert_nil warning(env: env), env }
  end

  def test_staging_and_other_deployed_environments_warn
    %w[production staging review qa].each { |env| refute_nil warning(env: env), env }
  end

  def test_a_safe_query_that_is_not_configured_stays_quiet
    Vroxy.reset_configuration!
    assert_nil BootCheck.message_for(config: Vroxy.configuration.safe_query, env: "production")
  end

  def test_a_disabled_safe_query_stays_quiet
    @config.enabled = false
    assert_nil warning
  end

  def test_it_logs_once_through_the_host_logger
    logger = RecordingLogger.new
    3.times { BootCheck.run(config: @config, env: "production", logger: logger, workers: nil) }

    assert_equal 1, logger.warnings.length
    assert BootCheck.warned?
    assert_match(/safe_query replay defence is in-process/, logger.warnings.first)
  end

  def test_a_logger_that_raises_never_takes_the_boot_down
    text = BootCheck.run(config: @config, env: "production", logger: ExplodingLogger.new, workers: nil)
    refute_nil text
  end

  def test_a_quiet_check_does_not_burn_the_one_warning
    logger = RecordingLogger.new
    BootCheck.run(config: @config, env: "test", logger: logger)
    refute BootCheck.warned?

    BootCheck.run(config: @config, env: "production", logger: logger, workers: nil)
    assert_equal 1, logger.warnings.length
  end

  def test_the_worker_count_comes_from_the_deployment_environment
    with_env("WEB_CONCURRENCY" => "5") { assert_equal 5, BootCheck.worker_count }
    with_env("WEB_CONCURRENCY" => "0") { assert_equal 0, BootCheck.worker_count }
    with_env("WEB_CONCURRENCY" => "", "PUMA_WORKERS" => "3") { assert_equal 3, BootCheck.worker_count }
    with_env("WEB_CONCURRENCY" => "auto", "PUMA_WORKERS" => nil) { assert_nil BootCheck.worker_count }
    with_env("WEB_CONCURRENCY" => nil, "PUMA_WORKERS" => nil) { assert_nil BootCheck.worker_count }
  end

  def test_the_reach_of_every_store_shape_is_classified
    assert_equal :none, BootCheck.store_reach(nil)
    assert_equal :process, BootCheck.store_reach(Vroxy::SafeQuery::NonceStore.new)
    assert_equal :process, BootCheck.store_reach(ActiveSupport::Cache::MemoryStore.new)
    assert_equal :process, BootCheck.store_reach(ActiveSupport::Cache::NullStore.new)
    assert_equal :shared, BootCheck.store_reach(SharedStore.new)
    assert_equal :process, BootCheck.store_reach(Object.new)
  end

  private

  def with_env(pairs)
    previous = pairs.keys.to_h { |key| [ key, ENV[key] ] }
    pairs.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
