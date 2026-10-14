# frozen_string_literal: true

require "test_helper"

class CanonicalTest < Minitest::Test
  def config
    @config ||= configured do |c|
      c.canonical_aliases = ["example.com", "example.onrender.com"]
      c.canonical_exclude_hosts = ["store.example.com"]
      c.host "docs.example.com"
    end
  end

  def test_aliases_fold_onto_the_canonical_origin
    assert_equal "https://www.example.com/pricing", config.canonical_url("http://example.com/pricing")
    assert_equal "https://www.example.com/pricing", config.canonical_url("https://EXAMPLE.onrender.com/pricing")
  end

  def test_query_and_fragment_are_dropped_unless_kept
    assert_equal "https://www.example.com/a", config.canonical_url("https://example.com/a?utm_source=x#top")
    config.canonical_keep_params = ["page"]
    assert_equal "https://www.example.com/a?page=2", config.canonical_url("/a?utm_source=x&page=2")
  end

  def test_paths_and_root
    assert_equal "https://www.example.com/", config.canonical_url("https://example.com")
    assert_equal "https://www.example.com/a/b/", config.canonical_url("/a/b/")
  end

  def test_unknown_hosts_fold_too
    assert_equal "https://www.example.com/x", config.canonical_url("https://evil.test/x")
  end

  def test_excluded_and_declared_hosts_keep_their_own_canonical
    assert_equal "https://store.example.com/item", config.canonical_url("http://store.example.com/item?ref=1")
    assert_equal "https://docs.example.com/guide", config.canonical_url("https://docs.example.com/guide")
  end

  def test_non_ascii_paths_are_percent_encoded_once
    assert_equal "https://www.example.com/%ED%95%9C%EA%B8%80", config.canonical_url("/한글")
    assert_equal "https://www.example.com/%ED%95%9C", config.canonical_url("/%ED%95%9C")
  end

  def test_requires_canonical_origin
    assert_raises(SeoGeo::ConfigurationError) { SeoGeo::Configuration.new.canonical_url("/") }
  end
end
