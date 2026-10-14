# frozen_string_literal: true

require "test_helper"

# Regressions for path normalization, robots directives and regexp timeouts. Each test replays a scenario through public
# behaviour, so it fails on fa43759 and passes once paths go through SeoGeo::RobotsPath, directives through
# SeoGeo::RobotsDirectives and configuration Regexps through SeoGeo::SafeRegexp.
class RobotsNormalizationTest < Minitest::Test
  HOST = "www.example.com"
  EVIL = /\A(a+)+\1\z/
  EVIL_PATH = %r{\A/(a+)+\1\z}
  SLOW_INPUT = "#{"a" * 40}!".freeze

  def setup
    @sitemap = SeoGeo::Sitemap::Registry.new
    @pages = SeoGeo::PageRegistry.new
    @pages.paths = []
    %i[home admin secret guide].each { |key| @pages.register(key, title: key.to_s.capitalize, description: "About #{key}.") }
  end

  def with_global_sitemap
    saved = SeoGeo.instance_variable_get(:@sitemap)
    SeoGeo.instance_variable_set(:@sitemap, @sitemap)
    yield
  ensure
    SeoGeo.instance_variable_set(:@sitemap, saved)
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  # a backtracking constraint held the worker before render admission.
  def test_og_param_constraint_redos_is_rejected_quickly
    config = configured do |c|
      c.og_image.permitted_params = ["title"]
      c.og_image.param_constraints = { "title" => EVIL }
    end
    params, seconds = timed { SeoGeo::OgImage.validated_params({ "title" => SLOW_INPUT }, config) }
    assert_nil params, "a timed-out constraint must reject (=> 400)"
    assert_operator seconds, :<, 1.0
    assert_equal({ "title" => "aaaa" }, SeoGeo::OgImage.validated_params({ "title" => "aaaa" }, config))
  end

  # noindex_paths and sitemap.exclude Regexps see request paths too; a timeout fails safe (noindex/excluded).
  def test_noindex_and_exclude_regexps_time_out_restrictively
    config = configured(environment: "production") { |c| c.noindex_paths = [EVIL_PATH] }
    noindex, seconds = timed { config.noindex_path?("/#{SLOW_INPUT}") }
    assert noindex, "timed-out noindex_paths Regexp => noindex"
    assert_operator seconds, :<, 1.0
    refute config.noindex_path?("/pricing")

    @sitemap.exclude EVIL_PATH
    excluded, seconds = timed { @sitemap.excluded?("/#{SLOW_INPUT}") }
    assert excluded, "timed-out exclusion Regexp => excluded"
    assert_operator seconds, :<, 1.0
  end

  # an encoded host disallow escaped the denied group's start_with? selection.
  def test_denied_group_carries_encoded_host_disallows
    config = configured(environment: "production") do |c|
      c.host HOST, disallow: ["/.%77ell-known/private"]
      c.crawlers.training = :deny
    end
    rules = SeoGeo::Robots::Evaluator.new(SeoGeo::Robots.new(config, HOST).to_s)
    refute rules.allowed?("*", "/.well-known/private")
    refute rules.allowed?("GPTBot", "/.well-known/private"), "denied bot must not get what * is denied"
    assert rules.allowed?("GPTBot", "/.well-known/assetlinks.json")
  end

  # encoded and Unicode paths, and .md URLs with a query, bypassed publication rules in llms-full.txt.
  def test_encoded_paths_and_md_queries_cannot_leak_copy
    config = configured(environment: "production") do |c|
      c.site.name = "Acme"
      c.host HOST, disallow: ["/admin", "/가이드"]
      c.noindex_paths = ["/secret"]
      c.llms_txt.page :home, path: "/"
      c.llms_txt.page :admin, path: "/%61dmin"
      c.llms_txt.page :guide, path: "/%EA%B0%80%EC%9D%B4%EB%93%9C"
      c.llms_txt.page :secret, path: "/secret.md?x=1"
    end
    llms = SeoGeo::LlmsTxt.new(config, HOST, pages: @pages, sitemap: @sitemap)
    full = llms.full
    assert_includes full, "## Home"
    refute_includes full, "## Admin", "/%61dmin is /admin"
    refute_includes full, "## Guide", "encoded /가이드 is disallowed"
    refute_includes full, "## Secret", "/secret.md?x=1 is the Markdown of /secret"
    refute_includes llms.to_s, "secret"
    refute SeoGeo::Publication.publishable?(HOST, "/%61dmin/x", config: config, sitemap: @sitemap)
  end

  # under default_noindex an index: true collection was in sitemap.xml while its head stayed noindex.
  def test_collection_index_reaches_the_head_through_match
    config = configured(environment: "production") { |c| c.default_noindex = true }
    @sitemap.add %w[a b], path: ->(slug) { "/posts/#{slug}" }, index: true, match: %r{\A/posts/[^/]+\z}
    locs = SeoGeo::Sitemap::Xml.new(config, @sitemap, HOST).urls.map(&:loc)
    assert_equal %w[https://www.example.com/posts/a https://www.example.com/posts/b], locs
    with_global_sitemap do
      locs.each { |loc| refute SeoGeo::Meta.new(config: config, url: loc).noindex?, "#{loc} is listed, so its head is indexable" }
      assert SeoGeo::Meta.new(config: config, url: "https://www.example.com/drafts/c").noindex?
    end
    @sitemap.add %w[c], path: ->(slug) { "/legacy/#{slug}" }, index: true
    assert_equal 1, @sitemap.unmatched_index_collections.size, "the audit names collections the head cannot match"
  end

  # a static index: true, hosts: [...] made the path indexable on every other host.
  def test_static_index_declaration_honors_hosts
    config = configured(environment: "production") do |c|
      c.default_noindex = true
      c.host HOST
      c.host "store.example.com"
      c.canonical_exclude_hosts = ["store.example.com"]
    end
    @sitemap.add "/pricing", index: true, hosts: [HOST]
    with_global_sitemap do
      refute SeoGeo::Meta.new(config: config, url: "https://www.example.com/pricing").noindex?
      assert SeoGeo::Meta.new(config: config, url: "https://store.example.com/pricing").noindex?
    end
    refute SeoGeo::Publication.publishable?("store.example.com", "/pricing", config: config, sitemap: @sitemap)
  end

  # content="none" and a second robots meta were not noindex for the audit.
  def test_audit_reads_every_robots_meta_and_none
    none = '<html><head><meta name="robots" content="none"></head><body></body></html>'
    second = '<html><head><meta name="robots" content="noarchive"><meta name="robots" content="noindex"></head></html>'
    bot = '<html><head><meta name="googlebot" content="noindex"></head></html>'
    [none, second, bot].each { |html| assert SeoGeo::Audit::HtmlDocument.new(html).noindex?, html }
    refute SeoGeo::Audit::HtmlDocument.new('<html><head><meta name="robots" content="index"></head></html>').noindex?
  end

  # %3F was decoded into a query delimiter, so /download%3Fpublic matched Allow: /download?public.
  def test_encoded_reserved_delimiters_stay_encoded
    rules = SeoGeo::Robots::Evaluator.new("User-agent: *\nDisallow: /\nAllow: /download?public\n")
    refute rules.allowed?("x", "/download%3Fpublic")
    assert rules.allowed?("x", "/download?public")
    slash = SeoGeo::Robots::Evaluator.new("User-agent: *\nDisallow: /a/b\n")
    assert slash.allowed?("x", "/a%2Fb"), "%2F is not a path separator"
    assert_equal "/download%3Fpublic", SeoGeo::RobotsPath.target("/download%3fpublic")
  end
end
