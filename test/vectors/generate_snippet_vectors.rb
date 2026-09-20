# Generates test/vectors/snippet_vectors.json — the cross-SDK
# contract every vroxy SDK must reproduce.
#
#   ruby -Ilib test/vectors/generate_snippet_vectors.rb
#
# The gem is the reference implementation, so the file is generated
# FROM it rather than hand-written, and then copied verbatim into
# vroxy_node, vroxy_python and vroxy_wordpress.  Hand-copying is what
# let the three snippet goldens drift to different case names and let
# the admin inspector stay Ruby-only for a release.
#
# What is pinned is the part that MUST be identical everywhere: the
# identify payload, byte for byte, and whether the inspector bundle is
# emitted at all.  The inspector's init args are deliberately NOT
# pinned — `controller_action` is "posts#index" in Rails, a route path
# in Express and a view name in Django, and forcing those to agree
# would be pinning a lie.

require "json"
require "vroxy"

class StubController
  def initialize(identity)
    @identity = identity
  end

  attr_reader :identity
end

RESOLVE = ->(ctrl) { ctrl.respond_to?(:identity) ? ctrl.identity : nil }

CASES = [
  { name: "anonymous",
    config: { api_key: "pk_test123" },
    identity: nil },

  { name: "unsigned_member",
    config: { api_key: "pk_1" },
    identity: { external_id: "7", email: "u@ex.com", name: "User Seven", role: "member" } },

  { name: "unsigned_admin_gets_no_inspector",
    config: { api_key: "pk_1" },
    identity: { external_id: "7", email: "u@ex.com", name: "User Seven", role: "admin" } },

  { name: "signed_member",
    config: { api_key: "pk_1", identity_secret: "is_sekrit" },
    identity: { external_id: "7", email: "u@ex.com", name: "User Seven", role: "member" } },

  { name: "signed_admin",
    config: { api_key: "pk_1", identity_secret: "is_sekrit" },
    identity: { external_id: "7", email: "u@ex.com", name: "User Seven", role: "admin" } },

  { name: "signed_custom_admin_role",
    config: { api_key: "pk_1", identity_secret: "is_sekrit", admin_roles: %w[manager] },
    identity: { external_id: "42", email: "m@ex.com", role: "manager", plan: "pro" } },

  { name: "admin_role_downgraded_by_explicit_level",
    config: { api_key: "pk_1", identity_secret: "is_sekrit" },
    identity: { external_id: "7", email: "u@ex.com", role: "admin", level: "user" } },

  { name: "explicit_admin_level_on_a_non_admin_role",
    config: { api_key: "pk_1", identity_secret: "is_sekrit" },
    identity: { external_id: "7", email: "u@ex.com", role: "member", level: "admin" } },

  { name: "sugar_keys_land_in_meta",
    config: { api_key: "pk_1" },
    identity: { email: "x@y.co", plan: "pro", signup_year: 2026 } },

  { name: "explicit_meta_wins_over_sugar",
    config: { api_key: "pk_1" },
    identity: { email: "x@y.co", plan: "pro", meta: { plan: "enterprise" } } },

  { name: "unicode_and_escapes",
    config: { api_key: "pk_1" },
    identity: { external_id: "ü42", email: "jürgen@exämple.de",
                name: "Jürgen <O'Brien> & Co", note: "quote\"backslash\\newline\n" } }
].freeze

vectors = CASES.map do |kase|
  Vroxy.reset_configuration!
  Vroxy.configure do |c|
    c.endpoint = "https://vroxy.ai"
    c.identify = RESOLVE
    kase[:config].each { |key, value| c.public_send("#{key}=", value) }
  end

  identity = kase[:identity]
  html     = Vroxy::Snippet.render(StubController.new(identity))

  {
    "name"      => kase[:name],
    "config"    => kase[:config].transform_keys(&:to_s),
    "identity"  => identity,
    "payload"   => identity ? Vroxy::Snippet.send(:identity_payload, identity, Vroxy.configuration) : nil,
    "inspector" => html.include?("admin_ui_inspector.js")
  }
end

out = File.expand_path("snippet_vectors.json", __dir__)
File.write(out, JSON.pretty_generate(vectors) + "\n")
puts "wrote #{vectors.size} vectors to #{out}"
