# frozen_string_literal: true

require "test_helper"

class ErrorReporterTest < Minitest::Test
  def setup
    super
    @captured = []
    Vroxy::ErrorReporter.transport = ->(payload, _config) { @captured << payload }
    Vroxy::ErrorReporter.reset_throttle!
    Vroxy.configure do |c|
      c.api_key       = "pk_1"
      c.endpoint      = "https://vroxy.test"
      c.report_errors = true
    end
  end

  def teardown
    Vroxy::ErrorReporter.transport = nil
    super
  end

  def boom
    raise ArgumentError, "boom"
  rescue ArgumentError => e
    e
  end

  def test_reports_with_class_message_backtrace_and_context
    assert Vroxy.report_error(boom, context: { user_id: 42 })

    payload = @captured.first
    assert_equal "ruby", payload[:source]
    assert_equal "ArgumentError", payload[:error_class]
    assert_equal "boom", payload[:message]
    assert payload[:backtrace].any? { |l| l.include?("error_reporter_test") }
    assert_equal "42", payload[:context]["user_id"]
    assert_equal true, payload[:context]["handled"]
  end

  def test_disabled_without_api_key
    Vroxy.configure { |c| c.api_key = nil }
    refute Vroxy.report_error(boom)
    assert_empty @captured
  end

  def test_disabled_when_report_errors_false
    Vroxy.configure { |c| c.report_errors = false }
    refute Vroxy.report_error(boom)
  end

  def test_auto_mode_is_off_outside_production
    Vroxy.configure { |c| c.report_errors = nil }
    refute Vroxy.configuration.report_errors?
  end

  def test_ignored_classes_and_their_subclasses_are_skipped
    Vroxy.configure { |c| c.error_ignore = %w[ArgumentError] }
    refute Vroxy.report_error(boom)

    subclass = Class.new(ArgumentError) { def self.name = "MySpecialArgError" }
    err = subclass.new("nope")
    err.set_backtrace([ "x.rb:1" ])
    refute Vroxy.report_error(err)
    assert_empty @captured
  end

  def test_blank_endpoint_disables_reporting
    Vroxy.configure { |c| c.endpoint = "" }
    refute Vroxy.report_error(boom)
  end

  def test_throttle_caps_reports_per_minute
    sent = 0
    100.times { sent += 1 if Vroxy.report_error(boom) }
    assert_equal Vroxy::ErrorReporter::MAX_PER_MINUTE, sent
  end

  def test_subscriber_forwards_unhandled_errors_with_source_context
    Vroxy::ErrorSubscriber.new.report(boom, handled: false, severity: :error,
                                        context: { job: "SyncJob" }, source: "application.active_job")
    payload = @captured.first
    assert_equal false, payload[:context]["handled"]
    assert_equal "application.active_job", payload[:context]["rails_source"]
    assert_equal "SyncJob", payload[:context]["job"]
  end

  def test_subscriber_skips_vroxy_sourced_errors
    Vroxy::ErrorSubscriber.new.report(boom, handled: false, severity: :error,
                                        context: {}, source: "vroxy.middleware")
    assert_empty @captured
  end

  def test_transport_failures_never_raise
    Vroxy::ErrorReporter.transport = ->(_p, _c) { raise "transport exploded" }
    refute Vroxy.report_error(boom)
  end
end
