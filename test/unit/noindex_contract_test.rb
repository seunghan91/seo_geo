# frozen_string_literal: true

require "test_helper"

# a path declared noindex is never in sitemap.xml or llms.txt, and the head says noindex.
class NoindexContractTest < Minitest::Test
  def setup
    @config = configured(environment: "production") do |c|
      c.site.name = "Acme"
      c.noindex_paths = ["/waitlist", %r{\A/drafts/}, "/가이드"]
    end
    @pages = SeoGeo::PageRegistry.new
    @pages.paths = []
    @sitemap = SeoGeo::Sitemap::Registry.new
    @sitemap.draw do
      add "/"
      add "/waitlist"
      add "/drafts/1"
      add "/가이드"
      add "/beta", noindex: true
      add "/pricing"
    end
  end

  def locs
    SeoGeo::Sitemap::Xml.new(@config, @sitemap, "www.example.com").urls.map(&:loc)
  end

  def test_sitemap_drops_declared_noindex_paths
    assert_equal %w[https://www.example.com/ https://www.example.com/pricing], locs
    refute_includes SeoGeo::Sitemap::Xml.new(@config, @sitemap, "www.example.com").render, "beta"
  end

  def test_registry_noindex_flag
    assert @sitemap.noindex?("/beta")
    refute @sitemap.noindex?("/pricing")
    error = assert_raises(SeoGeo::ConfigurationError) { @sitemap.add([1], path: ->(r) { "/#{r}" }, noindex: true) }
    assert_includes error.message, "static paths"
    assert_equal false, @sitemap.entries.first.noindex
  end

  def test_llms_txt_fallback_and_declared_links_skip_noindex
    body = SeoGeo::LlmsTxt.new(@config, "www.example.com", pages: @pages, sitemap: @sitemap).to_s
    assert_includes body, "https://www.example.com/pricing"
    %w[waitlist drafts beta %EA%B0%80].each { |part| refute_includes body, part }

    @config.llms_txt.link "Waitlist", "/waitlist"
    @config.llms_txt.link "Beta", "https://www.example.com/beta"
    @config.llms_txt.link "Pricing", "/pricing"
    body = SeoGeo::LlmsTxt.new(@config, "www.example.com", pages: @pages, sitemap: @sitemap).to_s
    assert_includes body, "[Pricing]"
    refute_includes body, "Waitlist"
    refute_includes body, "Beta"
  end

  def test_head_is_noindex_for_declared_paths_even_with_index_true
    meta = SeoGeo::Meta.new(config: @config, url: "https://www.example.com/%EA%B0%80%EC%9D%B4%EB%93%9C",
                            state: SeoGeo::Meta::State.new(index: true))
    assert meta.noindex?
    refute SeoGeo::Meta.new(config: @config, url: "https://www.example.com/pricing").noindex?

    saved = SeoGeo.instance_variable_get(:@sitemap)
    SeoGeo.instance_variable_set(:@sitemap, @sitemap)
    assert SeoGeo::Meta.new(config: @config, url: "https://www.example.com/beta").noindex?
    assert_nil SeoGeo::Meta.new(config: @config, url: "https://www.example.com/beta").markdown_url
  ensure
    SeoGeo.instance_variable_set(:@sitemap, saved)
  end

  def test_declarations_are_normalized_like_request_paths
    registry = SeoGeo::Sitemap::Registry.new
    registry.add "/beta?locale=en", noindex: true
    assert registry.noindex?("/beta")
    @config.noindex_paths = ["/%EA%B0%80"]
    assert @config.noindex_path?("/가")
  end
end
