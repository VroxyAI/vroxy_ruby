# frozen_string_literal: true

require "test_helper"

class DocsRegistryTest < Minitest::Test
  def setup
    Vroxy.reset_configuration!
  end

  def teardown
    Vroxy.reset_configuration!
  end

  def test_doc_dsl_registers_a_definition
    Vroxy.configure do |c|
      c.doc "Refunds", folder: "billing", slug: "refunds" do
        "Refunds are issued within 30 days."
      end
    end

    doc = Vroxy.configuration.docs.all.first
    assert_equal "Refunds", doc.title
    assert_equal "billing", doc.folder_path
    assert_equal "refunds", doc.slug
    assert_equal "seeded:gem:refunds", doc.marker
    assert_includes doc.body_md, "30 days"
  end

  def test_invalid_slug_is_refused
    err = assert_raises(ArgumentError) do
      Vroxy.configure do |c|
        c.doc "X", slug: "!!!" do
          "body"
        end
      end
    end
    assert_match(/slug/, err.message)
  end
end
