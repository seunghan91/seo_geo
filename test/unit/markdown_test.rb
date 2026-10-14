# frozen_string_literal: true

require "test_helper"

class MarkdownNegotiationTest < Minitest::Test
  def markdown?(accept) = SeoGeo::Markdown::Negotiation.markdown?(accept)

  def test_requires_explicit_text_markdown
    refute markdown?(nil)
    refute markdown?("")
    refute markdown?("*/*")
    refute markdown?("text/*")
    refute markdown?("text/html,application/xhtml+xml,*/*;q=0.8")
  end

  def test_q_values
    assert markdown?("text/markdown")
    assert markdown?("text/markdown;q=0.8, text/html;q=0.5")
    assert markdown?("text/html;q=0.9, text/markdown")
    assert markdown?("TEXT/MARKDOWN; Q=1, text/*;q=0.5")
    refute markdown?("text/markdown;q=0.5, text/html")
    refute markdown?("text/markdown;q=0.5, */*")
    refute markdown?("text/markdown;q=0")
  end

  def test_ties_follow_header_order
    assert markdown?("text/markdown, text/html, */*")
    refute markdown?("text/html, text/markdown")
  end
end

class MarkdownDocumentTest < Minitest::Test
  HTML = <<~HTML
    <html lang="ko"><head><title>제목</title><meta name="description" content="설명">
    <script type="application/ld+json">{"@type":"FAQPage"}</script>
    <script type="application/ld+json">not json</script></head>
    <body><header>Top</header><nav>Menu</nav><article><h2>Hello</h2><p>본문 <strong>굵게</strong></p></article>
    <footer>Bottom</footer></body></html>
  HTML

  def test_whole_body_strips_chrome_when_no_main
    doc = SeoGeo::Markdown::Document.new(HTML, config: configured, url: "https://example.com/a?x=1")
    out = doc.to_s
    assert_includes out, "## Hello"
    assert_includes out, "본문 **굵게**"
    %w[Top Menu Bottom].each { |text| refute_includes out, text }
    assert_equal({ "title" => "제목", "description" => "설명", "canonical" => "https://www.example.com/a", "locale" => "ko" },
                 doc.metadata)
    assert_includes out, "title: 제목"
    assert_includes out, "```json\n{\n  \"@type\": \"FAQPage\"\n}\n```"
    assert_includes out, "```json\nnot json\n```"
  end

  def test_custom_selector_and_converter
    config = configured { |c| c.markdown.converter = ->(html) { "CONVERTED #{html.strip}" } }
    out = SeoGeo::Markdown::Document.new(HTML, config: config, selector: "nav").to_s
    assert_includes out, "CONVERTED Menu"
  end

  def test_page_copy_for_empty_mount_point
    page = SeoGeo::Page.from_hash(:home, { title: "T", description: "D", heading: "H", intro: "I" }, locale: :en)
    html = '<html><head></head><body><div id="app" data-page="{}"></div></body></html>'
    doc = SeoGeo::Markdown::Document.new(html, config: configured, page: page)
    assert_equal "---\ntitle: T\ndescription: D\nlocale: en\n---\n\n# H\n\nI\n", doc.to_s
  end

  def test_noindex_detection
    html = '<html><head><meta name="robots" content="noindex, nofollow"></head><body><main>x</main></body></html>'
    assert_predicate SeoGeo::Markdown::Document.new(html, config: configured), :noindex?
  end

  def test_robots_none_expands_and_every_robots_meta_is_parsed
    html = '<html><head><meta name="robots" content="None"><meta name="ROBOTS" content="noarchive, max-snippet:0">' \
           '</head><body><main>x</main></body></html>'
    doc = SeoGeo::Markdown::Document.new(html, config: configured)
    assert_predicate doc, :noindex?
    assert_equal %w[noindex nofollow noarchive max-snippet:0], doc.robots_directives
  end

  def test_markdown_configuration_errors
    config = configured { |c| c.markdown.converter = :nope }
    assert_includes config.errors, "markdown.converter must be :reverse_markdown or respond to #call"
    config = configured { |c| c.markdown.selector = " " }
    assert_includes config.errors, "markdown.selector must be a non-empty String"
    assert_equal "main, [role=main]", configured.markdown.selector
  end
end

class MarkdownPathSuffixTest < Minitest::Test
  def call(path, method: "GET")
    seen = nil
    app = SeoGeo::Markdown::PathSuffix.new(->(env) { seen = env.slice("PATH_INFO", "HTTP_ACCEPT", "seo_geo.markdown"); [200, {}, []] })
    app.call("PATH_INFO" => path, "REQUEST_METHOD" => method, "HTTP_ACCEPT" => "text/html")
    seen
  ensure
    SeoGeo.reset!
  end

  def test_rewrites
    SeoGeo.reset!
    { "/index.md" => "/", "/docs/intro.md" => "/docs/intro", "/docs/index.md" => "/docs/", "/a.b.md" => "/a.b" }.each do |from, to|
      env = call(from)
      assert_equal to, env["PATH_INFO"], from
      assert_equal "text/markdown", env["HTTP_ACCEPT"]
      assert env["seo_geo.markdown"]
    end
  end

  def test_leaves_other_requests_alone
    assert_equal({ "PATH_INFO" => "/docs", "HTTP_ACCEPT" => "text/html" }, call("/docs"))
    assert_equal "/x.md", call("/x.md", method: "POST")["PATH_INFO"]
    SeoGeo.config.markdown.enabled = false
    seen = nil
    SeoGeo::Markdown::PathSuffix.new(->(env) { seen = env["PATH_INFO"]; [200, {}, []] })
                                .call("PATH_INFO" => "/x.md", "REQUEST_METHOD" => "GET")
    assert_equal "/x.md", seen
  ensure
    SeoGeo.reset!
  end
end
