# frozen_string_literal: true

require "test_helper"

class AdminRenderTrackerTest < Minitest::Test
  # `Vroxy::AdminRenderTracker` relies on ActiveSupport::Concern
  # for the `included do around_action ... end` block, so the
  # unit-test focus here is the private predicate that gates the
  # around_action.  End-to-end behavior (a real request emitting
  # `render_partial.action_view`) is covered by the vroxy
  # server's integration tests, not the gem's.
  #
  # We stub `Vroxy::Identity.resolve` because the gate reads
  # from it directly — that way each case dials in an identity
  # without needing a real controller.

  class FakeController
    # ActiveSupport::Concern's `included do ... end` block calls
    # `around_action`, which lives on AbstractController — we
    # don't have that here.  Stub it as a no-op class method
    # BEFORE the include so the callback registration doesn't
    # raise, then include the concern normally.
    def self.around_action(*_args, **_kwargs); end

    include Vroxy::AdminRenderTracker
  end

  # `define_singleton_method(:resolve)` REPLACES the singleton
  # copy `module_function` created — so a bare `remove_method` in
  # teardown deleted the real method for every test file that ran
  # after this one (order-dependent, surfaced by seed shuffle).
  # Save the original once and restore it instead.
  ORIGINAL_RESOLVE = Vroxy::Identity.method(:resolve)

  def teardown
    Vroxy::Identity.define_singleton_method(:resolve, ORIGINAL_RESOLVE)
    super
  end

  def stub_identity(hash)
    Vroxy::Identity.define_singleton_method(:resolve) { |_ctrl| hash }
  end

  def test_gate_true_for_admin_role
    stub_identity(role: "admin")
    assert FakeController.new.send(:vroxy_admin_render_tracking_enabled?)
  end

  def test_gate_true_for_owner_role
    stub_identity(role: "owner")
    assert FakeController.new.send(:vroxy_admin_render_tracking_enabled?)
  end

  def test_gate_reads_role_from_meta_when_top_level_absent
    stub_identity(email: "x@y.co", meta: { role: "admin" })
    assert FakeController.new.send(:vroxy_admin_render_tracking_enabled?)
  end

  def test_gate_false_for_basic_role
    stub_identity(role: "basic")
    refute FakeController.new.send(:vroxy_admin_render_tracking_enabled?)
  end

  def test_gate_false_for_anonymous
    stub_identity(nil)
    refute FakeController.new.send(:vroxy_admin_render_tracking_enabled?)
  end

  def test_gate_honors_configurable_admin_roles
    Vroxy.configure { |c| c.admin_roles = %w[manager] }
    stub_identity(role: "manager")
    assert FakeController.new.send(:vroxy_admin_render_tracking_enabled?)

    stub_identity(role: "admin")
    refute FakeController.new.send(:vroxy_admin_render_tracking_enabled?),
      "admin role should NOT trigger tracking when admin_roles is [manager]"
  end

  def test_gate_survives_identity_resolver_raising
    Vroxy::Identity.define_singleton_method(:resolve) { |_| raise "boom" }
    refute FakeController.new.send(:vroxy_admin_render_tracking_enabled?)
  end

  # `admin_roles = [:admin]` used to leave the gate permanently
  # false while the snippet still emitted the inspector tag — an
  # inspector that boots with an empty partial trail, forever.
  def test_gate_honors_symbol_admin_roles
    Vroxy.configure { |c| c.admin_roles = [ :admin, :owner ] }
    stub_identity(role: "admin")
    assert FakeController.new.send(:vroxy_admin_render_tracking_enabled?)
  end

  def test_gate_agrees_with_the_snippet_and_the_signed_level
    Vroxy.configure { |c| c.api_key = "pk_1"; c.admin_roles = [ :manager ] }
    identity = { role: "manager", email: "m@ex.com", external_id: "3" }
    stub_identity(identity)

    assert FakeController.new.send(:vroxy_admin_render_tracking_enabled?)
    assert_equal "admin", Vroxy::Identity.level_for(identity, Vroxy.configuration)
    assert_includes Vroxy::Snippet.render(Object.new), "admin_ui_inspector.js"
  end

  # `Rails.root` is not reachable from this suite, and the
  # subscriber that calls this runs inside a partial render — a
  # NameError there would take out the page it was measuring.
  def test_shorten_is_a_passthrough_when_rails_root_is_unavailable
    assert_equal "/gems/foo/_row.erb", FakeController.new.send(:shorten, "/gems/foo/_row.erb")
  end

  def render_partial(identifier)
    ActiveSupport::Notifications.instrument("render_partial.action_view", identifier: identifier) { nil }
  end

  def track
    controller = FakeController.new
    controller.send(:vroxy_track_rendered_partials) { yield }
    controller.instance_variable_get(:@_vroxy_rendered_partials)
  end

  # Everything below drives the real subscriber.  It runs inside a
  # partial render, so anything it raises takes out the page — and
  # nothing in the gem's own suite loads ActiveSupport's core_ext,
  # which is where the predicate it used to call lives.
  def test_subscriber_records_each_rendered_partial
    trail = track { render_partial("/app/views/posts/_row.html.erb") }

    assert_equal 1, trail.length
    assert_equal "/app/views/posts/_row.html.erb", trail.first[:path]
    assert_kind_of Float, trail.first[:ms]
  end

  def test_subscriber_skips_an_identifier_free_event
    trail = track do
      render_partial(nil)
      render_partial("")
      render_partial("/app/views/posts/_row.html.erb")
    end

    assert_equal [ "/app/views/posts/_row.html.erb" ], trail.map { |p| p[:path] }
  end

  # `render partial:, collection:` emits render_collection, and a
  # row partial rendered that way is the likeliest thing an admin
  # picks in the inspector.  Subscribing to render_partial alone
  # left the trail empty on exactly those pages.
  def test_subscriber_records_collection_renders
    trail = track do
      ActiveSupport::Notifications.instrument("render_collection.action_view",
                                              identifier: "/app/views/posts/_row.html.erb", count: 3) { nil }
    end

    assert_equal [ "/app/views/posts/_row.html.erb" ], trail.map { |p| p[:path] }
  end

  def test_subscriber_ignores_unrelated_view_events
    trail = track do
      ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "/app/views/posts/index.html.erb") { nil }
      render_partial("/app/views/posts/_row.html.erb")
    end

    assert_equal [ "/app/views/posts/_row.html.erb" ], trail.map { |p| p[:path] }
  end

  def test_subscriber_stops_at_the_runaway_guard
    trail = track do
      (Vroxy::AdminRenderTracker::MAX_PARTIALS + 25).times { |i| render_partial("/app/views/_row#{i}.erb") }
    end

    assert_equal Vroxy::AdminRenderTracker::MAX_PARTIALS, trail.length
  end

  # In a booted Rails app `blank?` is everywhere, so a file that
  # calls it without requiring it looks fine — right up until the
  # gem is loaded by something that hasn't pulled in the core_ext.
  # A sibling test file requiring `active_support/rails` hides that
  # in a combined run, so ask a clean process instead.
  def test_tracking_works_with_only_the_gems_own_requires
    script = <<~RUBY
      require "vroxy"
      klass = Class.new do
        def self.around_action(*_a, **_k); end
        include Vroxy::AdminRenderTracker
      end
      controller = klass.new
      controller.send(:vroxy_track_rendered_partials) do
        ActiveSupport::Notifications.instrument("render_partial.action_view", identifier: "/a/_row.erb") { nil }
      end
      trail = controller.instance_variable_get(:@_vroxy_rendered_partials)
      raise "expected one partial, got \#{trail.inspect}" unless trail.map { |p| p[:path] } == [ "/a/_row.erb" ]
    RUBY

    ok = system(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script,
                out: File::NULL, err: File::NULL)
    assert ok, "vroxy/admin_render_tracker must not depend on requires it doesn't make"
  end

  def test_subscriber_unsubscribes_after_the_action
    controller = FakeController.new
    controller.send(:vroxy_track_rendered_partials) { render_partial("/a/_one.erb") }
    render_partial("/a/_two.erb")

    trail = controller.instance_variable_get(:@_vroxy_rendered_partials)
    assert_equal [ "/a/_one.erb" ], trail.map { |p| p[:path] }
  end
end
