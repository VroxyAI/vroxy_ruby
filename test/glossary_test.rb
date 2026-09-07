# frozen_string_literal: true

require "test_helper"
require "i18n"

# The glossary is mined out of the host app's own i18n, so anything
# it gets wrong is published to the customer's bot as vocabulary.
class GlossaryTest < Minitest::Test
  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = [ :en ]
    I18n.locale = :en
  end

  def store(models)
    I18n.backend.store_translations(:en, activerecord: { models: models })
  end

  def test_plural_forms_become_aliases
    store(product: { one: "Listing", other: "Listings" })
    assert_equal [ { "term" => "product", "aliases" => %w[Listing Listings] } ],
                 Vroxy::Glossary.entries_from_i18n
  end

  # `activerecord.models.admin.user` is a NAMESPACED model, not a
  # set of plural forms.  Treating it as one published the term
  # "admin" aliased to the User label — vocabulary the app never had.
  def test_namespaced_models_are_skipped_not_mistaken_for_plurals
    store(admin: { user: "Administrator", account: "Ledger" })
    assert_empty Vroxy::Glossary.entries_from_i18n
  end

  def test_namespace_does_not_poison_its_siblings
    store(
      admin:   { user: "Administrator" },
      product: { one: "Listing", other: "Listings" }
    )
    terms = Vroxy::Glossary.entries_from_i18n.map { |e| e["term"] }
    assert_equal [ "product" ], terms
  end

  def test_label_matching_the_model_name_teaches_nothing
    store(user: "User", widget: "Widget")
    assert_empty Vroxy::Glossary.entries_from_i18n
  end

  def test_underscored_model_name_compares_against_its_spaced_form
    store(line_item: "Line item", invoice: "Bill")
    assert_equal [ "invoice" ], Vroxy::Glossary.entries_from_i18n.map { |e| e["term"] }
  end

  # The server validates every term and 422s the WHOLE payload on
  # one bad one — a single-letter model would sync nothing at all.
  def test_terms_the_server_would_refuse_are_dropped_not_sent
    store("a" => "Alpha", "x" * 41 => "Long", "invoice" => "Bill")
    assert_equal [ "invoice" ], Vroxy::Glossary.entries_from_i18n.map { |e| e["term"] }
  end

  def test_admin_url_template_builder_is_applied
    store(invoice: "Bill")
    Vroxy.configure { |c| c.glossary_admin_url = ->(term) { "https://app.test/admin/#{term}s/{id}" } }

    entry = Vroxy::Glossary.entries_from_i18n.first
    assert_equal "https://app.test/admin/invoices/{id}", entry["admin_url_template"]
  end

  def test_a_raising_admin_url_builder_does_not_lose_the_entry
    store(invoice: "Bill")
    Vroxy.configure { |c| c.glossary_admin_url = ->(_) { raise "no route" } }

    entry = Vroxy::Glossary.entries_from_i18n.first
    assert_equal "invoice", entry["term"]
    refute entry.key?("admin_url_template")
  end

  def test_glossary_extra_is_appended_verbatim
    store(invoice: "Bill")
    extra = { "term" => "seat", "aliases" => [ "licence" ] }
    Vroxy.configure { |c| c.glossary_extra = [ extra ] }

    assert_equal [ "invoice", "seat" ], Vroxy::Glossary.entries_from_i18n.map { |e| e["term"] }
  end

  def test_sync_refuses_without_a_secret_token
    Vroxy.configure { |c| c.secret_token = nil }
    err = assert_raises(RuntimeError) { Vroxy::Glossary.sync!([ { "term" => "x" } ]) }
    assert_match(/secret_token/, err.message)
  end
end
