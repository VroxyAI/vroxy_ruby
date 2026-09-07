# frozen_string_literal: true

class ApplicationController < ActionController::Base
  DemoUser = Struct.new(:id, :email, :name, :role, :plan)

  helper_method :current_user

  # Stands in for Devise / Clearance / your own session lookup.  The
  # gem calls whatever `current_user` returns; `?as=` switches
  # identities so you can watch the emitted snippet change.
  def current_user
    case params[:as]
    when "anonymous" then nil
    when "admin"     then DemoUser.new(1, "ada@example.com", "Ada Lovelace", "admin", "enterprise")
    else                  DemoUser.new(2, "grace@example.com", "Grace Hopper", "member", "starter")
    end
  end
end
