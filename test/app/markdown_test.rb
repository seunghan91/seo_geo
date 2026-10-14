# frozen_string_literal: true

require "test_helper"

class MarkdownTest < ActionDispatch::IntegrationTest
  MD = "text/markdown; charset=utf-8"

  def teardown
    SeoGeo.config.markdown.enabled = true
    SeoGeo.config.markdown.content_signal_header = true
    SeoGeo.config.aipref.enabled = false
  end

  def test_mime_type_is_registered
    assert_equal "text/markdown", Mime[:md].to_s
  end

  def test_accept_matrix
    {
      "text/html" => false,
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" => false,
      "*/*" => false,
      "text/markdown" => true,
      "text/markdown, text/html, */*" => true,
      "text/html, text/markdown" => false,
      "text/html;q=0.9, text/markdown" => true,
      "text/markdown;q=0.5, text/html" => false,
      "text/markdown;q=0" => false
    }.each do |accept, markdown|
      get "/guide", headers: { "Accept" => accept }
      assert_response :success
      if markdown
        assert_equal MD, response.headers["Content-Type"], accept
      else
        assert_equal "text/html", response.media_type, accept
      end
      assert_includes response.headers["Vary"].to_s, "Accept", accept
    end
  end

  def test_md_extension
    get "/guide.md"
    assert_response :success
    assert_equal MD, response.headers["Content-Type"]
    assert_match(/\A---\n/, response.body)
  end

  def test_index_md_maps_to_directory_without_a_route
    get "/docs/index.md"
    assert_response :success
    assert_equal MD, response.headers["Content-Type"]
  end

  def test_md_suffix_needs_no_format_route
    get "/docs.md"
    assert_response :success
    assert_equal MD, response.headers["Content-Type"]
    # The ERB fixture hard-codes its canonical link; the Inertia one falls back to the request URL minus .md.
    assert_includes response.body, "canonical: https://www.example.com/docs\n" if inertia_dummy?
  end

  def test_middleware_is_installed
    assert_includes Rails.application.middleware.map(&:klass), SeoGeo::Markdown::PathSuffix
  end

  def test_frontmatter_body_and_json_ld
    get "/guide", headers: { "Accept" => "text/markdown" }
    body = response.body
    front = YAML.safe_load(body[/\A---\n(.*?)\n---\n/m, 1])
    if inertia_dummy?
      assert_equal "Dummy home | Dummy", front["title"]
      assert_equal "The home page of the dummy application.", front["description"]
      assert_equal "https://www.example.com/guide", front["canonical"]
      assert_includes body, "# Welcome to Dummy"
      assert_includes body, "### Is this real?"
      refute_includes body, "```json"
    else
      assert_equal({ "title" => "Guide | Dummy", "description" => "How the dummy works.",
                     "canonical" => "https://www.example.com/guide",
                     "image" => "https://www.example.com/og/guide.png", "locale" => "en" }, front)
      assert_includes body, "# Guide"
      assert_includes body, "[the docs](/docs)"
      assert_includes body, "- One"
      refute_includes body, "Footer text"
      refute_includes body, "window.secret"
      refute_includes body, "color: red"
      refute_includes body, "[Home](/)"
      assert_includes body, "```json\n{\n  \"@context\": \"https://schema.org\""
    end
  end

  def test_content_signal_headers
    get "/guide", headers: { "Accept" => "text/markdown" }
    assert_equal "search=yes, ai-input=yes, ai-train=yes", response.headers["Content-Signal"]
    assert_nil response.headers["Content-Usage"]

    SeoGeo.config.aipref.enabled = true
    get "/guide", headers: { "Accept" => "text/markdown" }
    assert_equal "train-ai=y, search=y", response.headers["Content-Usage"]

    SeoGeo.config.markdown.content_signal_header = false
    get "/guide", headers: { "Accept" => "text/markdown" }
    assert_nil response.headers["Content-Signal"]
  end

  def test_html_response_has_no_content_signal
    get "/guide"
    assert_nil response.headers["Content-Signal"]
    assert_equal "Accept", response.headers["Vary"]
  end

  def test_noindex_html_becomes_x_robots_tag
    skip "the Inertia fixture has no robots meta" if inertia_dummy?

    get "/hidden", headers: { "Accept" => "text/markdown" }
    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  def test_robots_none_merges_with_existing_x_robots_tag
    skip "the Inertia fixture has no robots meta" if inertia_dummy?

    get "/robots_none", headers: { "Accept" => "text/markdown" }
    assert_equal MD, response.headers["Content-Type"]
    assert_equal "noindex, nofollow, googlebot: noarchive", response.headers["X-Robots-Tag"]
  end

  # a googlebot-scoped header must not swallow the HTML's global noindex.
  def test_scoped_header_keeps_the_global_html_noindex
    skip "the Inertia fixture has no robots meta" if inertia_dummy?

    get "/scoped_header", headers: { "Accept" => "text/markdown" }
    assert_equal "noindex, googlebot: nofollow, noindex", response.headers["X-Robots-Tag"]
  end

  def test_excluded_action_is_untouched
    get "/plain", headers: { "Accept" => "text/markdown, text/html, */*" }
    assert_equal "text/html", response.media_type
    refute_includes response.headers["Vary"].to_s, "Accept"
  end

  def test_disabled_serves_html
    SeoGeo.config.markdown.enabled = false
    get "/guide", headers: { "Accept" => "text/markdown, text/html" }
    assert_equal "text/html", response.media_type
  end
end
