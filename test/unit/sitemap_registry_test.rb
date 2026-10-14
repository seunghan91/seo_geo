# frozen_string_literal: true

require "test_helper"
require "date"

class SitemapRegistryTest < Minitest::Test
  Record = Struct.new(:slug, :updated_at)

  # Mimics an ActiveRecord relation: lazily enumerated with find_each.
  class FakeScope
    attr_reader :calls

    def initialize(records)
      @records = records
      @calls = 0
    end

    def find_each(&block)
      @calls += 1
      @records.each(&block)
    end
  end

  def setup
    SeoGeo.reset!
    SeoGeo.configure do |c|
      c.canonical_origin = "https://www.example.com"
      c.canonical_exclude_hosts = ["store.example.com"]
    end
  end

  def test_add_signature_and_resolution
    scope = FakeScope.new([Record.new("a", Date.new(2026, 10, 1)), Record.new("b", nil), Record.new("비밀", nil)])
    SeoGeo.sitemap.draw do
      add "/", priority: 1.0, changefreq: :daily
      add scope, path: ->(record) { "/p/#{record.slug}" }, lastmod: :updated_at
      add "/store", hosts: ["store.example.com"]
      exclude "/p/b"
    end
    assert_equal 0, scope.calls, "collections are enumerated lazily"

    urls = SeoGeo.sitemap.each_url("www.example.com").to_a
    assert_equal ["https://www.example.com/", "https://www.example.com/p/a", "https://www.example.com/p/%EB%B9%84%EB%B0%80"],
                 urls.map(&:loc)
    assert_equal [1.0, "daily"], [urls[0].priority, urls[0].changefreq]
    assert_equal Date.new(2026, 10, 1), urls[1].lastmod
    assert_nil urls[0].lastmod, "no lastmod is invented"
    assert_equal ["https://store.example.com/store"], SeoGeo.sitemap.each_url("store.example.com").map(&:loc)
  end

  def test_regexp_exclusions
    SeoGeo.sitemap.add "/s/abc"
    SeoGeo.sitemap.add "/about"
    SeoGeo.sitemap.exclude %r{\A/s/}
    assert_equal ["https://www.example.com/about"], SeoGeo.sitemap.each_url("www.example.com").map(&:loc)
  end

  def test_invalid_arguments
    registry = SeoGeo.sitemap
    assert_raises(SeoGeo::ConfigurationError) { registry.add "about" }
    assert_raises(SeoGeo::ConfigurationError) { registry.add "/", priority: 2 }
    assert_raises(SeoGeo::ConfigurationError) { registry.add "/", changefreq: "sometimes" }
    assert_raises(SeoGeo::ConfigurationError) { registry.add "/", path: ->(_) { "/" } }
    assert_raises(SeoGeo::ConfigurationError) { registry.add [Record.new("a")] }
    assert_raises(SeoGeo::ConfigurationError) { registry.add 42, path: :slug }
  end

  def test_clear
    SeoGeo.sitemap.add "/"
    SeoGeo.sitemap.clear
    assert_empty SeoGeo.sitemap.entries
  end
end
