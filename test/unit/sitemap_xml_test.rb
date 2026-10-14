# frozen_string_literal: true

require "test_helper"
# REXML is not a default gem on Ruby 3.4+; Nokogiri is already a runtime dependency (reverse_markdown).
require "nokogiri"

class SitemapXmlTest < Minitest::Test
  Record = Struct.new(:slug, :updated_at)

  def setup
    @config = configured(environment: "production") do |c|
      c.canonical_aliases = ["example.com"]
      c.host "www.example.com", disallow: ["/admin"]
      c.host "store.example.com"
    end
    @registry = SeoGeo::Sitemap::Registry.new
  end

  def xml(host = "www.example.com", page = nil, max_urls: SeoGeo::Sitemap::Xml::MAX_URLS)
    SeoGeo::Sitemap::Xml.new(@config, @registry, host, max_urls: max_urls).render(page)
  end

  def parse(document)
    Nokogiri::XML(document, &:strict)
  end

  def locs(document)
    parse(document).xpath("//*[local-name()='loc']").map(&:text)
  end

  def lastmods(document)
    parse(document).xpath("//*[local-name()='lastmod']").map(&:text)
  end

  def test_urlset_parses_with_real_lastmod_only
    @registry.add "/", priority: 1.0, changefreq: "daily"
    @registry.add [Record.new("a", Date.new(2026, 10, 1))], path: ->(r) { "/p/#{r.slug}" }, lastmod: :updated_at
    document = parse(xml)
    assert_equal "urlset", document.root.name
    assert_equal SeoGeo::Sitemap::Xml::XMLNS, document.root.namespace.href
    assert_equal %w[https://www.example.com/ https://www.example.com/p/a], locs(xml)
    assert_equal ["2026-10-01"], lastmods(xml)
    assert_includes xml, "<priority>1.0</priority>"
  end

  def test_korean_paths_are_percent_encoded_and_ampersands_escaped
    @registry.add "/가이드"
    @registry.add "/search?q=1&locale=ko"
    @config.canonical_keep_params = %w[q locale]
    output = xml
    assert_equal ["https://www.example.com/%EA%B0%80%EC%9D%B4%EB%93%9C", "https://www.example.com/search?q=1&locale=ko"],
                 locs(output)
    assert_includes output, "q=1&amp;locale=ko"
  end

  def test_excluded_and_disallowed_paths_are_dropped
    @registry.add "/"
    @registry.add "/admin/stats"
    @registry.add "/s/share-1"
    @registry.exclude %r{\A/s/}
    assert_equal ["https://www.example.com/"], locs(xml)
  end

  def test_404_cases
    assert_nil xml, "nothing registered"
    @registry.add "/"
    assert_nil xml("example.com"), "alias host has no sitemap"
    assert_nil xml("unknown.example.net"), "unknown host fails closed"
    assert_nil xml("store.example.com"), "declared host with no entries"
    assert_nil xml("www.example.com", 1), "parts exist only when split"
    @config.environment = "staging"
    assert_nil xml, "non-indexable environment"
  end

  def test_entries_for_other_hosts_use_that_origin
    @registry.add "/products", hosts: ["store.example.com"]
    assert_equal ["https://store.example.com/products"], locs(xml("store.example.com"))
    assert_nil xml
  end

  def test_splits_into_an_index_above_max_urls
    @registry.add (1..5).map { |n| Record.new(n.to_s, n == 4 ? Time.utc(2026, 9, 1, 12) : nil) },
                  path: ->(r) { "/n/#{r.slug}" }, lastmod: :updated_at
    assert_equal "sitemapindex", parse(xml(max_urls: 2)).root.name
    assert_equal %w[https://www.example.com/sitemap-1.xml https://www.example.com/sitemap-2.xml
                    https://www.example.com/sitemap-3.xml], locs(xml(max_urls: 2))
    assert_equal ["2026-09-01T12:00:00Z"], lastmods(xml(max_urls: 2))
    assert_equal %w[https://www.example.com/n/3 https://www.example.com/n/4], locs(xml("www.example.com", 2, max_urls: 2))
    assert_equal %w[https://www.example.com/n/5], locs(xml("www.example.com", 3, max_urls: 2))
    assert_nil xml("www.example.com", 4, max_urls: 2)
  end

  def test_real_limit_of_50_000
    items = Array.new(50_001) { |n| Record.new(n.to_s, nil) }
    @registry.add items, path: ->(r) { "/n/#{r.slug}" }
    assert_equal 2, locs(xml).length
    assert_includes xml, "<sitemapindex"
    assert_equal 1, locs(xml("www.example.com", 2)).length
  end
end
