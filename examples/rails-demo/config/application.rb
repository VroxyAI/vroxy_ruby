# frozen_string_literal: true

require "rails"
require "action_controller/railtie"
require "vroxy"

module RailsDemo
  class Application < Rails::Application
    config.root                       = File.expand_path("..", __dir__)
    config.eager_load                 = false
    config.consider_all_requests_local = true
    config.logger                     = ActiveSupport::Logger.new($stdout)
    config.secret_key_base            = ENV.fetch("SECRET_KEY_BASE", "vroxy-rails-demo-not-a-real-secret")
    config.hosts.clear
  end
end
