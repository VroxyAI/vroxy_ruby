# frozen_string_literal: true

require "test_helper"
require "active_support/rails"
require "rails/railtie"
require "rails/configuration"
require "action_dispatch"
require "rack"
require "vroxy/railtie"

# `config.middleware` inside an initializer is a RECORDER, not the
# stack: an operation is stored now and validated much later, when
# Rails merges it into the real stack.  A registration that names
# another middleware therefore fails at BOOT, in a place no rescue
# in the railtie can reach.
class RailtieMiddlewareTest < Minitest::Test
  FakeApp = Struct.new(:middleware)

  def register_vroxy_middleware
    app = FakeApp.new(Rails::Configuration::MiddlewareStackProxy.new)
    Vroxy::Railtie.initializers.find { |i| i.name == "vroxy.middleware" }.run(app)
    app.middleware
  end

  def default_stack(with_etag: true)
    stack = ActionDispatch::MiddlewareStack.new
    stack.use Rack::Runtime
    stack.use Rack::ETag if with_etag
    stack.use Rack::Head
    stack
  end

  def index_of(stack, klass)
    stack.middlewares.index { |m| m.klass == klass }
  end

  def test_boots_an_app_that_deleted_rack_etag
    stack = default_stack(with_etag: false)
    register_vroxy_middleware.merge_into(stack)

    refute_nil index_of(stack, Vroxy::Middleware),
               "the injector must still register when the app has no Rack::ETag"
  end

  # Outside Rack::ETag, two users' pages differ only in the identify
  # payload the digest was computed before we added — a conditional
  # GET could hand user A's identity to user B.
  def test_injector_lands_inside_rack_etag
    stack = default_stack
    register_vroxy_middleware.merge_into(stack)

    assert_operator index_of(stack, Vroxy::Middleware), :>, index_of(stack, Rack::ETag)
  end

  def test_naming_another_middleware_is_the_trap_this_avoids
    proxy = Rails::Configuration::MiddlewareStackProxy.new
    proxy.insert_after Rack::ETag, Vroxy::Middleware

    assert_raises(RuntimeError) { proxy.merge_into(default_stack(with_etag: false)) }
  end
end
