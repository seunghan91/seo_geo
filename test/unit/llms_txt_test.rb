# frozen_string_literal: true

require "test_helper"

class LlmsTxtTest < Minitest::Test
  def setup
    @config = configured(environment: "production") do |c|
      c.site.name = "Acme"
      c.site.description = "Acme sells anvils."
      c.canonical_aliases = ["example.com"]
    end
    @pages = SeoGeo::PageRegistry.new
    @pages.paths = []
    @pages.register(:home, title: "Home", description: "Start here.", heading: "Welcome", intro: "Hello.",
                           faq: [{ q: "Free?", a: "Yes." }])
    @pages.register(:pricing, title: "Pricing [2026]", description: "Plans and prices.")
    @sitemap = SeoGeo::Sitemap::Registry.new
  end

  def builder(host = "www.example.com")
    SeoGeo::LlmsTxt.new(@config, host, pages: @pages, sitemap: @sitemap)
  end

  def test_llmstxt_org_structure
    @config.llms_txt.details = "Anvils since 1920."
    @config.llms_txt.page :home, path: "/"
    @config.llms_txt.page :pricing, path: "/pricing", section: "Product"
    @config.llms_txt.link "Terms", "/terms", description: "Legal terms", optional: true
    @config.llms_txt.link "Docs", "https://docs.acme.dev/", section: "Product"
    assert_equal <<~TXT, builder.to_s
      # Acme

      > Acme sells anvils.

      Anvils since 1920.

      ## Pages

      - [Home](https://www.example.com/index.md): Start here.

      ## Product

      - [Pricing \\[2026\\]](https://www.example.com/pricing.md): Plans and prices.
      - [Docs](https://docs.acme.dev/)

      ## Optional

      - [Terms](https://www.example.com/terms): Legal terms
    TXT
  end

  def test_markdown_disabled_links_html
    @config.markdown.enabled = false
    @config.llms_txt.page :pricing, path: "/pricing"
    assert_includes builder.to_s, "- [Pricing \\[2026\\]](https://www.example.com/pricing): Plans and prices."
  end

  def test_falls_back_to_static_sitemap_paths
    @sitemap.add "/"
    @sitemap.add "/about"
    @sitemap.add "/s/x"
    @sitemap.exclude "/s/x"
    assert_includes builder.to_s, "## Pages\n\n- [/](https://www.example.com/)\n- [/about](https://www.example.com/about)\n"
  end

  def test_full_concatenates_page_markdown_under_one_h1
    @config.llms_txt.page :home, path: "/"
    @config.llms_txt.link "Terms", "/terms"
    full = builder.full
    assert_equal 1, full.scan(/^# /).length
    assert_includes full, "Source: https://www.example.com/\n\n## Welcome\n\nHello."
    assert_includes full, "### FAQ\n\n#### Free?\n\nYes."
    refute_includes full, "Terms"
  end

  def test_not_served_without_a_sitemap_host
    @config.llms_txt.page :home, path: "/"
    assert_nil builder("example.com").to_s
    assert_nil builder("evil.example.net").to_s
    @config.llms_txt.enabled = false
    assert_nil builder.to_s
  end

  def test_full_404_without_pages
    @config.llms_txt.link "Terms", "/terms"
    assert_nil builder.full
  end

  def test_invalid_link_path_is_a_config_error
    @config.llms_txt.link "Bad", "terms"
    assert(@config.errors.any? { |message| message.include?("llms_txt link") })
  end
end
