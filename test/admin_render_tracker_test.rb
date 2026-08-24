# frozen_string_literal: true

require "test_helper"

class AdminRenderTrackerTest < Minitest::Test
  # `Ctovibe::AdminRenderTracker` relies on ActiveSupport::Concern
  # for the `included do around_action ... end` block, so the
  # unit-test focus here is the private predicate that gates the
  # around_action.  End-to-end behavior (a real request emitting
  # `render_partial.action_view`) is covered by ctovibe_web's
  # integration tests, not the gem's.
  #
  # We stub `Ctovibe::Identity.resolve` because the gate reads
  # from it directly — that way each case dials in an identity
  # without needing a real controller.

  class FakeController
    # ActiveSupport::Concern's `included do ... end` block calls
    # `around_action`, which lives on AbstractController — we
    # don't have that here.  Stub it as a no-op class method
    # BEFORE the include so the callback registration doesn't
    # raise, then include the concern normally.
    def self.around_action(*_args, **_kwargs); end

    include Ctovibe::AdminRenderTracker
  end

  # `define_singleton_method(:resolve)` REPLACES the singleton
  # copy `module_function` created — so a bare `remove_method` in
  # teardown deleted the real method for every test file that ran
  # after this one (order-dependent, surfaced by seed shuffle).
  # Save the original once and restore it instead.
  ORIGINAL_RESOLVE = Ctovibe::Identity.method(:resolve)

  def teardown
    Ctovibe::Identity.define_singleton_method(:resolve, ORIGINAL_RESOLVE)
    super
  end

  def stub_identity(hash)
    Ctovibe::Identity.define_singleton_method(:resolve) { |_ctrl| hash }
  end

  def test_gate_true_for_admin_role
    stub_identity(role: "admin")
    assert FakeController.new.send(:ctovibe_admin_render_tracking_enabled?)
  end

  def test_gate_true_for_owner_role
    stub_identity(role: "owner")
    assert FakeController.new.send(:ctovibe_admin_render_tracking_enabled?)
  end

  def test_gate_reads_role_from_meta_when_top_level_absent
    stub_identity(email: "x@y.co", meta: { role: "admin" })
    assert FakeController.new.send(:ctovibe_admin_render_tracking_enabled?)
  end

  def test_gate_false_for_basic_role
    stub_identity(role: "basic")
    refute FakeController.new.send(:ctovibe_admin_render_tracking_enabled?)
  end

  def test_gate_false_for_anonymous
    stub_identity(nil)
    refute FakeController.new.send(:ctovibe_admin_render_tracking_enabled?)
  end

  def test_gate_honors_configurable_admin_roles
    Ctovibe.configure { |c| c.admin_roles = %w[manager] }
    stub_identity(role: "manager")
    assert FakeController.new.send(:ctovibe_admin_render_tracking_enabled?)

    stub_identity(role: "admin")
    refute FakeController.new.send(:ctovibe_admin_render_tracking_enabled?),
      "admin role should NOT trigger tracking when admin_roles is [manager]"
  end

  def test_gate_survives_identity_resolver_raising
    Ctovibe::Identity.define_singleton_method(:resolve) { |_| raise "boom" }
    refute FakeController.new.send(:ctovibe_admin_render_tracking_enabled?)
  end
end
