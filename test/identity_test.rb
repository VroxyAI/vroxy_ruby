# frozen_string_literal: true

require "test_helper"

class IdentityTest < Minitest::Test
  # Minimal test doubles — avoid ActiveRecord so the gem test
  # suite stays a plain Ruby run.
  class FakeUser
    attr_reader :id, :email, :full_name, :role

    def initialize(id:, email: nil, full_name: nil, role: nil)
      @id        = id
      @email     = email
      @full_name = full_name
      @role      = role
    end
  end

  class FakeController
    def initialize(user)
      @user = user
    end

    def current_user
      @user
    end
  end

  def test_returns_nil_without_current_user
    controller = Object.new
    assert_nil Vroxy::Identity.resolve(controller)
  end

  def test_auto_infers_from_current_user
    user = FakeUser.new(id: 42, email: "a@b.co", full_name: "Ada Lovelace", role: "admin")
    result = Vroxy::Identity.resolve(FakeController.new(user))

    assert_equal "42",           result[:external_id]
    assert_equal "a@b.co",       result[:email]
    assert_equal "Ada Lovelace", result[:name]
    assert_equal "admin",        result[:role]
  end

  def test_infers_name_from_first_last_when_full_name_absent
    user = Struct.new(:id, :email, :first_name, :last_name)
      .new(1, "x@y.co", "Grace", "Hopper")

    result = Vroxy::Identity.resolve(FakeController.new(user))
    assert_equal "Grace Hopper", result[:name]
  end

  def test_omits_nil_role_when_user_has_none
    user = FakeUser.new(id: 1, email: "x@y.co")
    result = Vroxy::Identity.resolve(FakeController.new(user))

    refute result.key?(:role), "role should be omitted, not nil"
  end

  def test_explicit_identify_block_overrides_auto_detect
    Vroxy.configure do |c|
      c.identify = ->(_ctrl) { { email: "override@ex.com", role: "vip", meta: { plan: "pro" } } }
    end

    user   = FakeUser.new(id: 1, email: "wrong@ex.com", role: "basic")
    result = Vroxy::Identity.resolve(FakeController.new(user))

    assert_equal "override@ex.com", result[:email]
    assert_equal "vip",             result[:role]
    assert_equal({ plan: "pro" },   result[:meta])
    refute result.key?(:external_id), "block return should not leak auto-inferred fields"
  end

  def test_identify_block_returning_nil_disables_identify
    Vroxy.configure { |c| c.identify = ->(_) { nil } }
    assert_nil Vroxy::Identity.resolve(FakeController.new(FakeUser.new(id: 1)))
  end

  def test_current_user_that_raises_falls_back_to_anonymous
    controller = Class.new do
      def current_user
        raise "boom"
      end
    end.new

    assert_nil Vroxy::Identity.resolve(controller)
  end
end
