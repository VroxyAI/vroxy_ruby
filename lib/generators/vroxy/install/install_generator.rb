# frozen_string_literal: true

require "rails/generators"

module Vroxy
  module Generators
    # `rails generate vroxy:install` — writes a commented
    # initializer with every knob the gem understands.  Keeping
    # the docs in the initializer (rather than a bare `api_key =`
    # line) means the customer's first real interaction with the
    # gem shows them the identify override, exclude paths, and
    # CSP nonce hook — all of which come up quickly in real apps.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Copies the vroxy initializer into config/initializers/"

      def copy_initializer
        template "vroxy.rb", "config/initializers/vroxy.rb"
      end
    end
  end
end
