# frozen_string_literal: true

require "test_helper"
require "support/robots_rules"

class RobotsTest < Minitest::Test
  def config(env: "production")
    configured(environment: env) do |c|
      c.canonical_aliases = ["example.com"]
      c.host "www.example.com", disallow: ["/admin", "/oauth/"]
      c.share_prefixes = ["/s/"]
      yield c if block_given?
    end
  end

  def robots(host, **options, &block)
    SeoGeo::Robots.new(config(**options, &block), host).to_s
  end

  def test_every_allowed_named_group_shares_the_star_rules
    body = robots("www.example.com")
    rules = RobotsRules.new(body)
    %w[* GPTBot ClaudeBot OAI-SearchBot ChatGPT-User Googlebot Yeti].each do |bot|
      refute rules.allowed?(bot, "/admin/users"), "#{bot} must not reach /admin"
      refute rules.allowed?(bot, "/oauth/authorize"), "#{bot} must not reach /oauth/"
      assert rules.allowed?(bot, "/"), "#{bot} must reach /"
      assert rules.allowed?(bot, "/s/abc"), "#{bot} must reach share links"
    end
    refute_match(/User-agent: GPTBot\nAllow: \/\n/, body)
  end

  def test_denied_purpose_gets_disallow_root_but_keeps_well_known
    body = robots("www.example.com") { |c| c.crawlers.training = :deny }
    rules = RobotsRules.new(body)
    %w[GPTBot ClaudeBot CCBot Google-Extended].each do |bot|
      refute rules.allowed?(bot, "/"), bot
      refute rules.allowed?(bot, "/s/abc"), "#{bot}: share links stay closed to denied purposes"
      assert rules.allowed?(bot, "/.well-known/assetlinks.json"), bot
    end
    assert rules.allowed?("OAI-SearchBot", "/")
    assert_includes body, "Content-Signal: search=yes, ai-input=yes, ai-train=no"
  end

  def test_override_denies_a_single_token
    rules = RobotsRules.new(robots("www.example.com") { |c| c.crawlers.override("Bytespider", :deny) })
    refute rules.allowed?("Bytespider", "/")
    assert rules.allowed?("GPTBot", "/")
  end

  def test_unknown_host_fails_closed_except_allow_exceptions
    body = robots("evil.example.net")
    rules = RobotsRules.new(body)
    refute rules.allowed?("Googlebot", "/")
    assert rules.allowed?("Googlebot", "/.well-known/assetlinks.json")
    assert rules.allowed?("Googlebot", "/s/abc")
    refute_includes body, "Sitemap:"
    refute_includes body, "Content-Signal"
  end

  def test_non_production_disallows_everything
    body = robots("www.example.com", env: "staging")
    rules = RobotsRules.new(body)
    refute rules.allowed?("Googlebot", "/")
    refute rules.allowed?("GPTBot", "/about")
    refute_includes body, "Sitemap:"
  end

  def test_sitemap_line_only_for_hosts_with_a_sitemap
    assert_includes robots("www.example.com"), "Sitemap: https://www.example.com/sitemap.xml"
    alias_body = robots("example.com")
    refute_includes alias_body, "Sitemap:"
    assert RobotsRules.new(alias_body).allowed?("Googlebot", "/"), "aliases stay crawlable so bots see the canonical link"
  end

  def test_no_disallow_list_emits_allow_root
    body = SeoGeo::Robots.new(configured(environment: "production"), "www.example.com").to_s
    assert_match(/\AUser-agent: \*\n(User-agent: .+\n)+Allow: \/\nContent-Signal: /, body)
  end

  def test_daum_pin_and_aipref
    body = robots("www.example.com") do |c|
      c.verification.daum_pin = "abc123"
      c.aipref.enabled = true
      c.crawlers.training = :deny
    end
    assert_includes body, "#DaumWebMasterTool:abc123"
    assert_includes body, "Content-Usage: train-ai=n, search=y"
    refute_includes robots("www.example.com"), "Content-Usage"
    refute_includes robots("evil.example.net") { |c| c.verification.daum_pin = "abc123" }, "DaumWebMasterTool"
  end

  def test_no_named_group_reaches_a_path_the_star_group_disallows
    paths = %w[/ /admin /admin/x /oauth/a /s/abc /.well-known/assetlinks.json /.well-known/private
               /.well-known/private/key /.well-known/privatex /about]
    %i[allow deny].repeated_permutation(3).each do |training, search, user|
      body = robots("www.example.com") do |c|
        c.host "www.example.com", disallow: ["/admin", "/oauth/", "/.well-known/private"]
        c.crawlers.training = training
        c.crawlers.search = search
        c.crawlers.user = user
      end
      rules = RobotsRules.new(body)
      (rules.agents - ["*"]).each do |bot|
        paths.each do |path|
          next if rules.allowed?("*", path)

          refute rules.allowed?(bot, path), "#{bot} (#{training}/#{search}/#{user}) reaches #{path}"
        end
      end
      refute rules.allowed?("*", "/.well-known/private/key")
      assert rules.allowed?("*", "/.well-known/assetlinks.json")
    end
  end
end
