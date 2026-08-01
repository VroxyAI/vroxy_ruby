# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "rack/test"
require "ctovibe"

module CtovibeTestSupport
  # Fresh config for every test — the singleton would otherwise
  # leak state between files (identify blocks especially, since
  # a stale one from an earlier test can silently satisfy the
  # next).
  def setup
    Ctovibe.reset_configuration!
    super
  end
end

Minitest::Test.include CtovibeTestSupport
