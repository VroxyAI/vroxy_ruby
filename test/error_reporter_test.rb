# frozen_string_literal: true

require "test_helper"

class ErrorReporterTest < Minitest::Test
  def setup
    super
    @captured = []
    Ctovibe::ErrorReporter.transport = ->(payload, _config) { @captured << payload }
    Ctovibe::ErrorReporter.reset_throttle!
    Ctovibe.configure do |c|
      c.api_key       = "pk_1"
      c.endpoint      = "https://ctovibe.test"
      c.report_errors = true
    end
  end

  def teardown
    Ctovibe::ErrorReporter.transport = nil
    super
  end

  def boom
    raise ArgumentError, "boom"
  rescue ArgumentError => e
    e
  end

  def test_reports_with_class_message_backtrace_and_context
    assert Ctovibe.report_error(boom, context: { user_id: 42 })

    payload = @captured.first
    assert_equal "ruby", payload[:source]
    assert_equal "ArgumentError", payload[:error_class]
    assert_equal "boom", payload[:message]
    assert payload[:backtrace].any? { |l| l.include?("error_reporter_test") }
    assert_equal "42", payload[:context]["user_id"]
    assert_equal true, payload[:context]["handled"]
  end

  def test_disabled_without_api_key
    Ctovibe.configure { |c| c.api_key = nil }
    refute Ctovibe.report_error(boom)
    assert_empty @captured
  end

  def test_disabled_when_report_errors_false
    Ctovibe.configure { |c| c.report_errors = false }
    refute Ctovibe.report_error(boom)
  end

  def test_auto_mode_is_off_outside_production
    Ctovibe.configure { |c| c.report_errors = nil }
    refute Ctovibe.configuration.report_errors?
  end

  def test_ignored_classes_and_their_subclasses_are_skipped
    Ctovibe.configure { |c| c.error_ignore = %w[ArgumentError] }
    refute Ctovibe.report_error(boom)

    subclass = Class.new(ArgumentError) { def self.name = "MySpecialArgError" }
    err = subclass.new("nope")
    err.set_backtrace([ "x.rb:1" ])
    refute Ctovibe.report_error(err)
    assert_empty @captured
  end

  def test_blank_endpoint_disables_reporting
    Ctovibe.configure { |c| c.endpoint = "" }
    refute Ctovibe.report_error(boom)
  end

  def test_throttle_caps_reports_per_minute
    sent = 0
    100.times { sent += 1 if Ctovibe.report_error(boom) }
    assert_equal Ctovibe::ErrorReporter::MAX_PER_MINUTE, sent
  end

  def test_subscriber_forwards_unhandled_errors_with_source_context
    Ctovibe::ErrorSubscriber.new.report(boom, handled: false, severity: :error,
                                        context: { job: "SyncJob" }, source: "application.active_job")
    payload = @captured.first
    assert_equal false, payload[:context]["handled"]
    assert_equal "application.active_job", payload[:context]["rails_source"]
    assert_equal "SyncJob", payload[:context]["job"]
  end

  def test_subscriber_skips_ctovibe_sourced_errors
    Ctovibe::ErrorSubscriber.new.report(boom, handled: false, severity: :error,
                                        context: {}, source: "ctovibe.middleware")
    assert_empty @captured
  end

  def test_transport_failures_never_raise
    Ctovibe::ErrorReporter.transport = ->(_p, _c) { raise "transport exploded" }
    refute Ctovibe.report_error(boom)
  end
end
