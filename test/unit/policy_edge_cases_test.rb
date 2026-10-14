# frozen_string_literal: true

require "test_helper"
require "support/robots_rules"

# Edge cases: alias indexability, query-specific robots rules in llms.txt, unavailable_after dates, page locale. See also install_generator_test.rb, test/app/og_image_test.rb,
# boot_without_initializer_test.rb.
class PolicyEdgeCasesTest < Minitest::Test
  HOST = "www.example.com"

  # #2: a non-indexable canonical host said Disallow: / while its undeclared alias said Allow: /.
  def test_alias_inherits_canonical_indexability
    config = configured(environment: "production") do |c|
      c.canonical_aliases = ["example.com"]
      c.host HOST, indexable: false
    end
    policy = config.host_policy("example.com")
    refute policy.indexable
    refute policy.sitemap
    rules = RobotsRules.new(SeoGeo::Robots.new(config, "example.com").to_s)
    refute rules.allowed?("*", "/about")
    refute rules.allowed?("GPTBot", "/about")
  end

  # #3: llms dropped the query before robots matching, so Disallow: /secret?preview=1 did not apply.
  def test_llms_keeps_the_query_for_robots_rules
    config = configured(environment: "production") do |c|
      c.site.name = "Acme"
      c.host HOST, disallow: ["/secret?preview=1"]
      c.llms_txt.page :home, path: "/"
      c.llms_txt.page :secret, path: "/secret?preview=1"
      c.llms_txt.page :preview, path: "/secret.md?preview=1"
    end
    pages = SeoGeo::PageRegistry.new
    pages.paths = []
    %i[home secret preview].each { |key| pages.register(key, title: key.to_s.capitalize) }
    full = SeoGeo::LlmsTxt.new(config, HOST, pages: pages, sitemap: SeoGeo::Sitemap::Registry.new).full
    assert_includes full, "## Home"
    refute_includes full, "## Secret"
    refute_includes full, "## Preview"
    assert_equal "/secret?preview=1", SeoGeo::RobotsPath.html_target("/secret.md?preview=1")
  end

  # #4: the comma inside an unavailable_after date opened a bogus "03 dec 2025 13" scope.
  def test_unavailable_after_dates_keep_their_comma
    header = "unavailable_after: Wed, 03 Dec 2025 13:09:53 GMT, noindex"
    directives = SeoGeo::RobotsDirectives.parse_header(header)
    assert_empty directives.scoped
    assert directives.noindex?
    assert_includes directives.global, "unavailable_after: Wed, 03 Dec 2025 13:09:53 GMT"
    assert_equal header, directives.to_header
    merged = directives.merge(SeoGeo::RobotsDirectives.from_html('<meta name="robots" content="nofollow">'))
    assert_equal "#{header}, nofollow", merged.to_header
    scoped = SeoGeo::RobotsDirectives.parse_header("googlebot: unavailable_after: Wed, 03 Dec 2025 13:09:53 GMT")
    assert_equal ["googlebot"], scoped.scoped.keys
    meta = SeoGeo::RobotsDirectives.from_html('<meta name="robots" content="unavailable_after: Wed, 03 Dec 2025 13:09:53 GMT">')
    assert_equal ["unavailable_after: Wed, 03 Dec 2025 13:09:53 GMT"], meta.global.to_a
  end

  # #6: the head used site.default_locale but SeoGeo.page / the fallback body used I18n.locale.
  def test_default_page_fetch_follows_the_request_locale_rule
    SeoGeo.reset!
    SeoGeo.config.site.default_locale = :ko
    SeoGeo.pages.register(:home, { en: { title: "Home" }, ko: { title: "홈" } })
    I18n.with_locale(:en) do
      assert_equal "홈", SeoGeo.page(:home).title
      SeoGeo.config.locales = %i[ko en]
      assert_equal "Home", SeoGeo.page(:home).title
    end
  ensure
    SeoGeo.reset!
  end
end
