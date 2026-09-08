# frozen_string_literal: true

source "https://rubygems.org"

gemspec

install_if -> { ENV["VROXY_TEST_ADAPTER"].to_s.start_with?("p") } do
  gem "pg", ">= 1.5"
end
