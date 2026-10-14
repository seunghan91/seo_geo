# frozen_string_literal: true

require "test_helper"

# one publication predicate for sitemap.xml, llms.txt, llms-full.txt and the head
# (regressions).
class PublicationTest < Minitest::Test
  def setup
    @config = configured(environment: "production") do |c|
      c.site.name = "Acme"
      c.host "www.example.com", disallow: ["/admin"]
    end
    @pages = SeoGeo::PageRegistry.new
    @pages.paths = []
    %i[home admin secret pricing].each { |key| @pages.register(key, title: key.to_s.capitalize, description: "About #{key}.") }
    @sitemap = SeoGeo::Sitemap::Registry.new
  end

  def locs
    SeoGeo::Sitemap::Xml.new(@config, @sitemap, "www.example.com").urls.map { |url| url.loc.delete_prefix("https://www.example.com") }
  end

  def llms
    SeoGeo::LlmsTxt.new(@config, "www.example.com", pages: @pages, sitemap: @sitemap)
  end

  def publishable?(path, host = "www.example.com")
    SeoGeo::Publication.publishable?(host, path, config: @config, sitemap: @sitemap)
  end

  def test_predicate_combines_every_rule
    @config.noindex_paths = ["/hidden"]
    @sitemap.exclude %r{\A/s/}
    @sitemap.add "/beta", noindex: true
    assert publishable?("/pricing")
    refute publishable?("/admin/users"), "robots disallow"
    refute publishable?("/s/abc"), "sitemap exclusion"
    refute publishable?("/hidden"), "noindex_paths"
    refute publishable?("/beta"), "registry noindex"
    refute publishable?("/pricing", "example.com"), "alias host has no sitemap"
    refute publishable?("/pricing", "unknown.test"), "fail-closed host"
  end

  # default_noindex pages were listed in sitemap.xml.
  def test_default_noindex_lists_only_entries_declared_index
    @config.default_noindex = true
    @sitemap.add "/"
    @sitemap.add "/pricing", index: true
    @sitemap.add %w[a b], path: ->(slug) { "/posts/#{slug}" }, index: true
    @sitemap.add %w[c], path: ->(slug) { "/drafts/#{slug}" }
    assert_equal %w[/pricing /posts/a /posts/b], locs
    assert SeoGeo::Publication.declared_index?("www.example.com", "/pricing", config: @config, sitemap: @sitemap)
    refute publishable?("/")
    assert_raises(SeoGeo::ConfigurationError) { @sitemap.add "/x", index: true, noindex: true }
  end

  # auto links ignored robots; explicit links ignored exclusions; llms-full leaked their copy.
  def test_llms_auto_links_drop_robots_disallowed_paths
    @sitemap.add "/"
    @sitemap.add "/admin/stats"
    body = llms.to_s
    assert_includes body, "https://www.example.com/"
    refute_includes body, "/admin"
  end

  def test_llms_explicit_links_and_full_respect_every_rule
    @sitemap.exclude "/secret"
    @config.llms_txt.page :home, path: "/"
    @config.llms_txt.page :admin, path: "/admin"
    @config.llms_txt.page :secret, path: "/secret"
    @config.llms_txt.link "Secret too", "https://www.example.com/secret"
    @config.llms_txt.link "Elsewhere", "https://docs.other.test/secret"
    body = llms.to_s
    refute_includes body, "Admin"
    refute_includes body, "Secret"
    assert_includes body, "[Elsewhere](https://docs.other.test/secret)", "other origins pass through"
    full = llms.full
    assert_includes full, "Source: https://www.example.com/"
    refute_includes full, "About admin."
    refute_includes full, "About secret."
  end

  def test_llms_markdown_flag
    @config.llms_txt.page :home, path: "/"
    @config.llms_txt.page :pricing, path: "/pricing", markdown: false
    @config.llms_txt.link "Docs", "/docs", markdown: true
    @config.llms_txt.link "Terms", "/terms", markdown: false
    @config.llms_txt.link "Default", "/default"
    @config.llms_txt.page :secret, path: "/blog", markdown: nil
    @config.llms_txt.link "Elsewhere", "https://docs.other.test/guide", markdown: true
    body = llms.to_s
    assert_includes body, "[Default](https://www.example.com/default)", "plain links: nil => HTML URL"
    assert_includes body, "[Secret](https://www.example.com/blog.md)", "registered pages: nil => markdown.enabled"
    assert_includes body, "[Elsewhere](https://docs.other.test/guide)", "other origins are never rewritten"
    assert_includes body, "](https://www.example.com/index.md)"
    assert_includes body, "[Pricing](https://www.example.com/pricing)"
    assert_includes body, "[Docs](https://www.example.com/docs.md)"
    assert_includes body, "[Terms](https://www.example.com/terms)"

    @config.markdown.enabled = false
    body = llms.to_s
    refute_includes body, ".md)"
  end

  # same-origin spelled differently, .md links, collections under default_noindex.
  def test_llms_same_origin_variants_and_markdown_forms_are_judged
    @config.noindex_paths = ["/secret"]
    @config.llms_txt.link "Upper", "https://WWW.EXAMPLE.COM/secret"
    @config.llms_txt.link "Port", "https://www.example.com:443/secret"
    @config.llms_txt.link "Md", "/secret.md"
    @config.llms_txt.link "Ok", "/pricing"
    body = llms.to_s
    %w[Upper Port Md].each { |title| refute_includes body, "[#{title}]" }
    assert_includes body, "[Ok]"
  end

  def test_llms_links_to_indexed_collection_records_survive_default_noindex
    @config.default_noindex = true
    @sitemap.add %w[a], path: ->(slug) { "/posts/#{slug}" }, index: true
    @config.llms_txt.link "Post A", "/posts/a"
    @config.llms_txt.link "Post B", "/posts/b"
    body = llms.to_s
    assert_includes body, "[Post A]"
    refute_includes body, "[Post B]"
  end

  def test_sitemap_entries_carry_the_markdown_flag_into_the_llms_fallback
    @sitemap.add "/", markdown: false
    @sitemap.add "/guide", markdown: true
    @sitemap.add "/about"
    body = llms.to_s
    assert_includes body, "[/](https://www.example.com/)"
    assert_includes body, "[/guide](https://www.example.com/guide.md)"
    assert_includes body, "[/about](https://www.example.com/about)", "fallback entries: nil => HTML URL"
    assert @sitemap.markdown_disabled?("/")
    refute @sitemap.markdown_disabled?("/about")
    refute @sitemap.entries.first.markdown?(@config)
    @config.markdown.enabled = false
    refute_includes llms.to_s, ".md)"
  end

  # llms-full.txt renders page copy only for publishable entries (same predicate as llms.txt).
  def test_llms_full_uses_only_publishable_pages
    @config.default_noindex = true
    @config.llms_txt.page :home, path: "/"
    @config.llms_txt.page :pricing, path: "/pricing"
    @sitemap.add "/pricing", index: true
    full = llms.full
    assert_includes full, "Source: https://www.example.com/pricing"
    refute_includes full, "Source: https://www.example.com/\n"
    refute_includes full, "## Home"
  end
end
