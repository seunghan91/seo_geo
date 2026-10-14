# frozen_string_literal: true

require "test_helper"
require "support/robots_rules"
require "seo_geo/testing"
require "seo_geo/rspec"

# Integration options: audit Host header, og:image size, lazy sitemap collections, full_access, intro, llms details, test helpers (fallback slot: test/app/head_test.rb).
class IntegrationOptionsTest < Minitest::Test
  HOST = "www.example.com"

  # #5: the audit sent no Host header, so Rails HostAuthorization (config.hosts) answered 403 for every URL.
  def test_audit_passes_rails_host_authorization
    require "action_view"
    require "action_dispatch"
    require "action_dispatch/middleware/host_authorization"
    config = configured(environment: "production")
    inner = ->(_env) { [200, { "content-type" => "text/plain" }, ["User-agent: *\nAllow: /\n"]] }
    app = ActionDispatch::HostAuthorization.new(inner, [HOST, "example.com"])
    report = SeoGeo::Audit::Runner.new(app: app, config: config, sitemap: SeoGeo::Sitemap::Registry.new, hosts: [HOST]).run
    refute(report.findings.any? { |item| item.check == "host_authorization" }, report.to_s)
    refute(report.findings.any? { |item| item.message.include?("403") }, report.to_s)
  end

  # #6: 1200x630 was claimed for a static fallback image of another size.
  def test_og_image_size_only_when_known
    config = configured { |c| c.og_image.fallback_url = "https://cdn.example.com/og.jpg" }
    image = ->(**state) { SeoGeo::Meta.new(config: config, url: "https://www.example.com/", state: SeoGeo::Meta::State.new(**state)).tags[:og][:image] }
    assert_equal({ _: "https://cdn.example.com/og.jpg" }, image.call)
    config.og_image.fallback_width = 800
    config.og_image.fallback_height = 400
    assert_equal({ _: "https://cdn.example.com/og.jpg", width: 800, height: 400 }, image.call)
    assert_equal({ _: "https://www.example.com/og/home.png" }, image.call(image: "/og/home.png"), "app route, gem OG off")
    config.og_image.backend = ->(*) {}
    assert_equal({ _: "https://www.example.com/og/home.png", width: 1200, height: 630 }, image.call(image: "/og/home.png"))
    assert_equal({ _: "https://www.example.com/a.png", width: 10, height: 20 }, image.call(image: { url: "/a.png", width: 10, height: 20 }))
    config.og_image.fallback_width = 0
    assert_includes config.errors, "og_image.fallback_width must be a positive Integer or nil"
  end

  # #7: collections were evaluated at boot; a lambda defers them to each sitemap request; batch: false keeps order.
  def test_lazy_collection_and_ordered_each
    config = configured(environment: "production")
    calls = 0
    rows = %w[b a]
    scope = Struct.new(:rows) do
      def find_each(&) = rows.sort.each(&)
      def each(&) = rows.each(&)
    end
    registry = SeoGeo::Sitemap::Registry.new
    registry.add(-> { calls += 1; scope.new(rows) }, path: ->(slug) { "/p/#{slug}" })
    assert_equal 0, calls, "nothing evaluated at registration"
    locs = -> { SeoGeo::Sitemap::Xml.new(config, registry, HOST).urls.map { |url| url.loc.delete_prefix("https://www.example.com") } }
    assert_equal %w[/p/a /p/b], locs.call, "find_each by default"
    rows << "c"
    assert_equal %w[/p/a /p/b /p/c], locs.call, "re-evaluated per request"
    assert_equal 2, calls
    registry.clear
    registry.add(-> { scope.new(rows) }, path: ->(slug) { "/p/#{slug}" }, batch: false)
    assert_equal %w[/p/b /p/a /p/c], locs.call, "each keeps the scope order"
    assert_raises(SeoGeo::ConfigurationError) { registry.add "/x", batch: false }
  end

  # #8: an explicit, opt-in full allow for one crawler.
  def test_full_access_override
    config = configured(environment: "production") do |c|
      c.host HOST, disallow: ["/admin"]
      c.crawlers.override "Mediapartners-Google", :full_access
    end
    rules = RobotsRules.new(SeoGeo::Robots.new(config, HOST).to_s)
    assert rules.allowed?("Mediapartners-Google", "/admin")
    refute rules.allowed?("*", "/admin")
    refute rules.allowed?("GPTBot", "/admin"), "nobody else gains access"
    assert_empty config.errors
    closed = configured(environment: "development") { |c| c.crawlers.override "Mediapartners-Google", :full_access }
    refute RobotsRules.new(SeoGeo::Robots.new(closed, HOST).to_s).allowed?("Mediapartners-Google", "/")
    refute_includes SeoGeo::Robots.new(configured(environment: "production"), HOST).to_s, "Mediapartners-Google"
  end

  # #10: intro may be a String or an Array; props keep q/a normalized to question/answer.
  def test_intro_string_or_array_and_props_shape
    page = SeoGeo::Page.from_hash(:x, { title: "T", intro: ["One.", "Two."], faq: [{ q: "Q?", a: "A." }], cta: "Go" })
    assert_equal ["One.", "Two."], page.intro_paragraphs
    assert_equal "# T\n\nOne.\n\nTwo.\n\n## FAQ\n\n### Q?\n\nA.\n", page.to_markdown
    assert_equal %i[key locale title description heading intro features faq cta], page.props.keys
    assert_equal [{ question: "Q?", answer: "A." }], page.props[:faq]
    assert_equal ["Lead."], SeoGeo::Page.from_hash(:y, { intro: "Lead." }).intro_paragraphs
  end

  # #11: headings in llms_txt.details are kept (H1/H2 demoted so the file keeps one H1 and H2 link sections).
  def test_llms_details_allow_headings
    config = configured(environment: "production") do |c|
      c.site.name = "Acme"
      c.llms_txt.details = "## About\n\nText.\n\n### Pricing\n\n```\n# not a heading\n```"
      c.llms_txt.link "Home", "/"
    end
    body = SeoGeo::LlmsTxt.new(config, HOST, pages: SeoGeo::PageRegistry.new, sitemap: SeoGeo::Sitemap::Registry.new).to_s
    assert_includes body, "### About\n\nText.\n\n### Pricing\n\n```\n# not a heading\n```"
    assert_equal 1, body.sub(/```.*?```/m, "").scan(/^# /).size
    assert_equal ["## Pages"], body.scan(/^## .*/)
  end

  # #12: with_environment for Minitest and RSpec.
  def test_with_environment_helpers
    SeoGeo.config.environment = "test"
    seen = SeoGeo::Testing.with_environment(:production) { SeoGeo.config.environment_name }
    assert_equal "production", seen
    assert_equal "test", SeoGeo.config.environment_name
    minitest = Object.new.extend(SeoGeo::Testing::Assertions)
    rspec = Object.new.extend(SeoGeo::RSpec::Matchers)
    [minitest, rspec].each do |host|
      assert_equal "production", host.with_seo_geo_environment("production") { SeoGeo.config.environment_name }
    end
    assert_raises(RuntimeError) { SeoGeo::Testing.with_environment("production") { raise "boom" } }
    assert_equal "test", SeoGeo.config.environment_name
  ensure
    SeoGeo.config.environment = nil
  end

  # markdown.path_suffix = false: an app with its own .md routes keeps them; nothing advertises .md URLs.
  def test_markdown_path_suffix_can_be_turned_off
    saved = SeoGeo.config.markdown.path_suffix
    SeoGeo.config.markdown.path_suffix = false
    app = SeoGeo::Markdown::PathSuffix.new(->(env) { [200, { "content-type" => "text/plain" }, [env["PATH_INFO"]]] })
    status, _, body = app.call(Rack::MockRequest.env_for("/notes/today.md"))
    assert_equal [200, ["/notes/today.md"]], [status, body]
    config = configured(environment: "production") { |c| c.markdown.path_suffix = false }
    assert_nil SeoGeo::Meta.new(config: config, url: "https://www.example.com/pricing").markdown_url
    config.llms_txt.page :home, path: "/"
    pages = SeoGeo::PageRegistry.new
    pages.paths = []
    pages.register(:home, title: "Home")
    body = SeoGeo::LlmsTxt.new(config, HOST, pages: pages, sitemap: SeoGeo::Sitemap::Registry.new).to_s
    assert_includes body, "[Home](https://www.example.com/)"
    refute_includes body, "index.md"
  ensure
    SeoGeo.config.markdown.path_suffix = saved
  end
end

