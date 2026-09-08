# frozen_string_literal: true

require "test_helper"
require "active_support/string_inquirer"
require "rails/railtie"
require "vroxy/railtie"

class RailtieBootCheckTest < Minitest::Test
  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(message)
      @warnings << message
    end
  end

  def test_the_after_initialize_hook_warns_through_the_host_logger
    logger = RecordingLogger.new

    Vroxy.configure do |config|
      config.safe_query.secret = "qs_#{'c' * 40}"
      config.safe_query.model "Deal", columns: %w[id]
    end

    hook = vroxy_after_initialize_hook
    refute_nil hook, "the railtie must register an after_initialize hook"

    with_rails_stub(env: "production", logger: logger) { hook.call(Object.new) }

    assert_equal 1, logger.warnings.length
    assert_match(/safe_query replay defence is in-process/, logger.warnings.first)
  end

  def test_the_hook_stays_quiet_in_development
    logger = RecordingLogger.new

    Vroxy.configure do |config|
      config.safe_query.secret = "qs_#{'d' * 40}"
      config.safe_query.model "Deal", columns: %w[id]
    end

    with_rails_stub(env: "development", logger: logger) { vroxy_after_initialize_hook.call(Object.new) }

    assert_empty logger.warnings
  end

  private

  def setup
    super
    Vroxy::SafeQuery::BootCheck.reset!
  end

  def teardown
    Vroxy::SafeQuery::BootCheck.reset!
    super
  end

  def vroxy_after_initialize_hook
    hooks = ActiveSupport.instance_variable_get(:@load_hooks)[:after_initialize] || []
    entry = hooks.find do |candidate|
      block = candidate.is_a?(Array) ? candidate.first : candidate
      block.respond_to?(:source_location) && block.source_location.to_a.first.to_s.end_with?("vroxy/railtie.rb")
    end
    entry.is_a?(Array) ? entry.first : entry
  end

  def with_rails_stub(env:, logger:)
    stubbed_env    = !Rails.respond_to?(:env)
    stubbed_logger = !Rails.respond_to?(:logger)
    Rails.define_singleton_method(:env) { ActiveSupport::StringInquirer.new(env) } if stubbed_env
    Rails.define_singleton_method(:logger) { logger } if stubbed_logger
    yield
  ensure
    Rails.singleton_class.send(:remove_method, :env) if stubbed_env
    Rails.singleton_class.send(:remove_method, :logger) if stubbed_logger
  end
end
