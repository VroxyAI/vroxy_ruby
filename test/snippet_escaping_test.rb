# frozen_string_literal: true

require "test_helper"
require "json"

# Everything the snippet writes into a <script> body is JSON built
# from customer data — a display name, a meta value, a partial path.
# JSON alone is not enough inside HTML: `</script>` in a string value
# closes the element and the rest is parsed as markup.
class SnippetEscapingTest < Minitest::Test
  BREAKOUT = %q{</script><img src=x onerror=alert(1)>}

  class FakeController
    def initialize(user = nil)
      @user = user
    end

    def current_user
      @user
    end

    def controller_path; "posts"; end
    def action_name;     "index"; end
  end

  FakeUser = Struct.new(:id, :email, :full_name, :role)

  def identify_payload(html)
    match = html.match(/vroxy\("identify", (\{.*?\})\);/m)
    refute_nil match, "identify call not found in: #{html}"
    JSON.parse(match[1])
  end

  def test_display_name_cannot_close_the_script_tag
    Vroxy.configure { |c| c.api_key = "pk_1" }
    html = Vroxy::Snippet.render(FakeController.new(FakeUser.new(1, "a@b.co", BREAKOUT, nil)))

    refute_includes html, "</script><img", "a user's name closed the script element"
    assert_equal 2, html.scan("</script>").length, "exactly one closing tag per emitted script"
    assert_includes html, '</script>'
  end

  def test_escaped_payload_still_decodes_to_the_original_value
    Vroxy.configure { |c| c.api_key = "pk_1" }
    html = Vroxy::Snippet.render(FakeController.new(FakeUser.new(1, "a@b.co", BREAKOUT, nil)))

    assert_equal BREAKOUT, identify_payload(html)["name"]
  end

  LINE_SEPARATOR      = 0x2028.chr(Encoding::UTF_8)
  PARAGRAPH_SEPARATOR = 0x2029.chr(Encoding::UTF_8)

  def test_ampersand_and_line_separators_are_escaped
    Vroxy.configure { |c| c.api_key = "pk_1" }
    name = "A&B#{LINE_SEPARATOR}C#{PARAGRAPH_SEPARATOR}D"
    html = Vroxy::Snippet.render(FakeController.new(FakeUser.new(1, "a@b.co", name, nil)))

    refute_includes html, LINE_SEPARATOR, "U+2028 terminates a line in pre-ES2019 engines"
    refute_includes html, PARAGRAPH_SEPARATOR
    assert_includes html, "\\u2028"
    assert_includes html, "\\u2029"
    assert_includes html, "\\u0026"
    assert_equal name, identify_payload(html)["name"]
  end

  def test_meta_values_are_escaped_too
    Vroxy.configure do |c|
      c.api_key  = "pk_1"
      c.identify = ->(_) { { email: "a@b.co", meta: { plan: BREAKOUT } } }
    end
    html = Vroxy::Snippet.render(FakeController.new)

    refute_includes html, "</script><img"
    assert_equal BREAKOUT, identify_payload(html).dig("meta", "plan")
  end

  def test_inspector_init_args_are_escaped
    Vroxy.configure { |c| c.api_key = "pk_1" }
    controller = FakeController.new(FakeUser.new(1, "a@b.co", "Ada", "admin"))
    controller.instance_variable_set(:@_vroxy_rendered_partials,
                                     [ { path: "app/views/#{BREAKOUT}.erb", ms: 1.0 } ])

    html = Vroxy::Snippet.render(controller)

    assert_includes html, "VroxyInspector.init("
    refute_includes html, "</script><img"
    args = JSON.parse(html[/VroxyInspector\.init\((\{.*?\})\);/m, 1])
    assert_equal "app/views/#{BREAKOUT}.erb", args["rendered_partials"].first["path"]
  end
end
