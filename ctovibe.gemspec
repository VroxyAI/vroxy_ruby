# frozen_string_literal: true

require_relative "lib/ctovibe/version"

Gem::Specification.new do |spec|
  spec.name        = "ctovibe"
  spec.version     = Ctovibe::VERSION
  spec.authors     = ["ctovibe"]
  spec.email       = ["hello@ctovibe.io"]

  spec.summary     = "Rails integration for the ctovibe support widget."
  spec.description = "Drop-in Rails gem: set your ctovibe API key and the " \
                     "widget snippet auto-injects on every HTML response, " \
                     "with current_user identity (email / name / role) " \
                     "forwarded to ctovibe.identify()."
  spec.homepage    = "https://ctovibe.io"
  spec.license     = "MIT"

  # Rails 7.1 is the floor because we lean on ActionController::Base's
  # modern `helper_method` semantics + Zeitwerk-friendly file layout.
  # Ruby 3.1 is the floor for `Hash#except`-on-symbols + pattern
  # matching sugar the middleware uses.
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/**/*.rake",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.1", "< 9.0"
  spec.add_dependency "actionpack", ">= 7.1", "< 9.0"

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "rake", "~> 13.0"
end
