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

# An app that IS a vroxy deployment serves the widget from a relative
# URL, so `endpoint` is "" — but a server-side POST needs somewhere
# absolute to go. That split is what `ingest_endpoint` exists for.
class IngestEndpointTest < Minitest::Test
  def setup
    Vroxy.reset_configuration!
    Vroxy::ErrorReporter.transport = nil
  end

  def teardown
    Vroxy.reset_configuration!
    Vroxy::ErrorReporter.transport = nil
  end

  def test_ingest_endpoint_defaults_to_endpoint
    Vroxy.configure { |c| c.endpoint = "https://vroxy.ai" }

    assert_equal "https://vroxy.ai", Vroxy.configuration.ingest_endpoint
  end

  def test_an_empty_endpoint_no_longer_disables_reporting
    sent = []
    Vroxy::ErrorReporter.transport = ->(payload, _cfg) { sent << payload }
    Vroxy.configure do |c|
      c.api_key         = "pk_test"
      c.endpoint        = ""
      c.ingest_endpoint = "https://self.example"
      c.report_errors   = true
    end

    assert Vroxy::ErrorReporter.report(RuntimeError.new("boom"))
    assert_equal 1, sent.size
  end

  def test_no_ingest_base_anywhere_still_refuses
    Vroxy.configure do |c|
      c.api_key       = "pk_test"
      c.endpoint      = ""
      c.report_errors = true
    end

    assert_equal "", Vroxy.configuration.ingest_endpoint.to_s
    refute Vroxy.configuration.report_errors?,
           "with nowhere to POST, reporting must read as off rather than silently failing per-exception"
    refute Vroxy::ErrorReporter.report(RuntimeError.new("boom"))
  end

  def test_the_post_goes_to_the_ingest_base_not_the_asset_base
    Vroxy.configure do |c|
      c.api_key         = "pk_test"
      c.endpoint        = "https://cdn.example"
      c.ingest_endpoint = "https://self.example"
      c.report_errors   = true
    end

    assert_equal "https://self.example", Vroxy.configuration.ingest_endpoint
  end
end
