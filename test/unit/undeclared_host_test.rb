# frozen_string_literal: true

require "test_helper"

# An undeclared host is served noindex + Disallow: / (fail closed). In an indexable environment that usually means a
# proxy dropped the Host header or an apex/www mismatch, so it is logged once per host per process.
class UndeclaredHostTest < Minitest::Test
  def setup
    SeoGeo::UndeclaredHost.reset!
    @config = configured(environment: "production") { |c| c.canonical_aliases = ["example.com"] }
  end

  def teardown
    SeoGeo::UndeclaredHost.reset!
  end

  def warnings
    _, err = capture_io { yield }
    err.lines.map(&:strip).reject(&:empty?)
  end

  def test_head_warns_once_per_undeclared_host
    meta = ->(host) { SeoGeo::Meta.new(config: @config, url: "http://#{host}/pricing") }
    logged = warnings do
      2.times { assert meta.call("127.0.0.1").noindex? }
      assert meta.call("10.0.0.5").noindex?
      refute meta.call("www.example.com").noindex?
      refute meta.call("example.com").noindex?
    end
    assert_equal [
      'seo_geo: host "127.0.0.1" is not declared (canonical_origin/canonical_aliases/host); serving noindex + Disallow: /. Check proxy Host headers.',
      'seo_geo: host "10.0.0.5" is not declared (canonical_origin/canonical_aliases/host); serving noindex + Disallow: /. Check proxy Host headers.'
    ], logged
  end

  def test_quiet_outside_indexable_environments
    config = configured(environment: "development")
    assert_empty(warnings { assert SeoGeo::Meta.new(config: config, url: "http://127.0.0.1/").noindex? })
  end
end
