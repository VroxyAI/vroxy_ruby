# frozen_string_literal: true

require "test_helper"
require "json"

# The cross-SDK contract.  vroxy_node, vroxy_python and
# vroxy_wordpress each carry a verbatim copy of this file and assert
# the same two things against it, so a change to the payload shape or
# the inspector gate cannot land in one SDK and quietly skip the rest.
#
# Regenerate with:
#   ruby -Ilib test/vectors/generate_snippet_vectors.rb
class SnippetVectorsTest < Minitest::Test
  VECTORS = JSON.parse(File.read(File.expand_path("vectors/snippet_vectors.json", __dir__)))

  def setup
    super
    Vroxy.reset_configuration!
  end

  def teardown
    Vroxy.reset_configuration!
    super
  end

  class Stub
    def initialize(identity)
      @identity = identity
    end

    attr_reader :identity
  end

  # Reset per VECTOR, not per test: one vector's identity_secret
  # leaking into the next turns an unsigned case into a signed one.
  def configure_for(vector)
    Vroxy.reset_configuration!
    Vroxy.configure do |c|
      c.endpoint = "https://vroxy.ai"
      c.identify = ->(ctrl) { ctrl.respond_to?(:identity) ? ctrl.identity : nil }
      vector["config"].each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  def symbolize(identity)
    return nil if identity.nil?
    identity.each_with_object({}) do |(k, v), out|
      out[k.to_sym] = v.is_a?(Hash) ? symbolize(v) : v
    end
  end

  def test_every_vector_reproduces_its_identify_payload
    VECTORS.each do |vector|
      configure_for(vector)
      identity = symbolize(vector["identity"])
      next if identity.nil?

      actual = Vroxy::Snippet.send(:identity_payload, identity, Vroxy.configuration)

      assert_equal vector["payload"],
                   JSON.parse(JSON.generate(actual)),
                   "payload drift on vector #{vector['name']}"
    end
  end

  def test_every_vector_reproduces_its_inspector_decision
    VECTORS.each do |vector|
      configure_for(vector)
      html = Vroxy::Snippet.render(Stub.new(symbolize(vector["identity"])))

      assert_equal vector["inspector"],
                   html.include?("admin_ui_inspector.js"),
                   "inspector drift on vector #{vector['name']}"
    end
  end

  # Named explicitly so a regenerated file that silently DROPS a case
  # cannot read as a pass.  Both gates below are ones a plausible
  # refactor gets wrong, so losing either is worth a failure.
  def test_the_vector_set_still_covers_both_inspector_traps
    names = VECTORS.map { |v| v["name"] }

    assert_includes names, "unsigned_admin_gets_no_inspector"
    assert_includes names, "explicit_admin_level_on_a_non_admin_role"
    assert_operator VECTORS.size, :>=, 11
  end
end
