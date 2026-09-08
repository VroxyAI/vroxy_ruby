# frozen_string_literal: true

require_relative "lib/vroxy/version"

Gem::Specification.new do |spec|
  spec.name        = "vroxy"
  spec.version     = Vroxy::VERSION
  spec.authors     = ["vroxy"]
  spec.email       = ["hello@vroxy.ai"]

  spec.summary     = "Rails integration for the vroxy support widget."
  spec.description = "Drop-in Rails gem: set your vroxy API key and the " \
                     "widget snippet auto-injects on every HTML response, " \
                     "with current_user identity (email / name / role) " \
                     "forwarded to vroxy.identify()."
  spec.homepage    = "https://vroxy.ai"
  spec.license     = "MIT"

  spec.metadata = {
    "allowed_push_host" => "none",
    "source_code_uri"   => "https://github.com/VroxyAI/vroxy_ruby",
    "changelog_uri"     => "https://github.com/VroxyAI/vroxy_ruby/blob/main/CHANGELOG.md"
  }

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

  spec.add_development_dependency "activerecord", ">= 7.1", "< 9.0"
  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "sqlite3", ">= 2.1"
end
