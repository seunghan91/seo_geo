# frozen_string_literal: true

require "test_helper"

class HostPolicyTest < Minitest::Test
  def config
    @config ||= configured(environment: "production") do |c|
      c.canonical_aliases = ["example.com"]
      c.canonical_exclude_hosts = ["store.example.com"]
      c.share_prefixes = ["/s/"]
      c.host "www.example.com", disallow: ["/admin"], allow: ["/admin/public"]
      c.host "api.example.com", indexable: false
    end
  end

  def test_declared_canonical_host
    policy = config.host_policy("WWW.example.com:443")
    assert_equal "www.example.com", policy.host
    assert policy.indexable
    assert policy.sitemap
    assert policy.known
    assert_equal ["/admin"], policy.disallow
    assert_equal ["/.well-known/", "/s/", "/admin/public"], policy.allow
    assert policy.frozen?
  end

  def test_alias_defaults_to_crawlable_without_sitemap
    policy = config.host_policy("example.com")
    assert policy.indexable
    refute policy.sitemap
  end

  def test_excluded_host_defaults_to_its_own_sitemap
    assert config.host_policy("store.example.com").sitemap
  end

  def test_non_indexable_host
    policy = config.host_policy("api.example.com")
    refute policy.indexable
    refute policy.sitemap
    assert policy.disallow_all?
  end

  def test_unknown_host_fails_closed_but_keeps_exceptions
    policy = config.host_policy("random.test")
    refute policy.known
    refute policy.indexable
    refute policy.sitemap
    assert_equal ["/"], policy.disallow
    assert_equal ["/.well-known/", "/s/"], policy.allow
  end

  def test_non_production_disables_indexing_everywhere
    config.environment = "staging"
    policy = config.host_policy("www.example.com")
    refute policy.indexable
    refute policy.sitemap
    assert policy.disallow_all?
  end

  def test_known_hosts_and_origin_for
    assert_equal %w[www.example.com example.com store.example.com api.example.com], config.known_hosts
    assert_equal "https://www.example.com", config.origin_for("www.example.com")
    assert_equal "https://store.example.com", config.origin_for("store.example.com")
  end
end
