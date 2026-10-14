# frozen_string_literal: true

require "test_helper"
require "support/robots_rules"

# Alias hosts inherit the canonical host's robots policy; one locale rule for lang, inLanguage and og:locale. See also boot_without_initializer_test.rb,
# test/app/og_image_test.rb and install_generator_test.rb.
class AliasHostPolicyTest < Minitest::Test
  def alias_config
    configured(environment: "production") do |c|
      c.canonical_origin = "https://www.example.com"
      c.canonical_aliases = ["example.com"]
      c.host "www.example.com", disallow: ["/admin", "/oauth/"], allow: ["/admin/public"]
      c.share_prefixes = ["/s/"]
      c.crawlers.training = :deny
    end
  end

  # an alias host without its own c.host said Allow: / — /admin was open there.
  def test_alias_host_robots_disallow_what_the_canonical_host_disallows
    config = alias_config
    canonical = RobotsRules.new(SeoGeo::Robots.new(config, "www.example.com").to_s)
    aliased = RobotsRules.new(SeoGeo::Robots.new(config, "example.com").to_s)
    assert_equal canonical.agents.sort, aliased.agents.sort
    %w[/ /admin /admin/users /admin/public /oauth/authorize /s/abc /about].each do |path|
      aliased.agents.each do |bot|
        assert_equal canonical.allowed?(bot, path), aliased.allowed?(bot, path), "#{bot} #{path} on the alias"
      end
    end
    refute aliased.allowed?("*", "/admin")
    refute aliased.allowed?("GPTBot", "/admin")
    policy = config.host_policy("example.com")
    assert_equal ["/admin", "/oauth/"], policy.disallow
    refute policy.sitemap, "aliases still serve no sitemap"
  end

  def test_alias_with_its_own_host_declaration_keeps_it
    config = alias_config
    config.host "example.com", disallow: ["/"]
    assert_equal ["/"], config.host_policy("example.com").disallow
  end

  # a Korean app without I18n got lang="en" and no og:locale.
  def test_locale_follows_default_locale_unless_locales_lists_i18n_locale
    config = configured { |c| c.site.default_locale = :ko; c.site.name = "Acme" }
    assert_equal :ko, config.request_locale(:en), "I18n.locale :en without config.locales"
    meta = SeoGeo::Meta.new(config: config, url: "https://www.example.com/", locale: config.request_locale(:en))
    assert_equal "ko_KR", meta.tags[:og][:locale]
    assert_equal "ko", meta.json_ld.to_h["@graph"].find { |node| node["@type"] == "WebSite" }["inLanguage"]

    config.locales = %i[ko en]
    assert_equal :en, config.request_locale(:en)
    assert_equal :ko, config.request_locale(:ja)
    assert_equal "en_US", config.og_locale(:en)
    assert_equal "en_GB", config.og_locale(:"en-GB")
    assert_nil config.og_locale(:xx)
  end
end
