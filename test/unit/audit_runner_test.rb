# frozen_string_literal: true

require "test_helper"

# Runner against a canned Rack app (no Rails): checks that need responses the engine never produces.
class AuditRunnerTest < Minitest::Test
  PAGE = <<~HTML
    <!DOCTYPE html><html lang="en"><head><title>%<title>s</title>
    <meta name="description" content="A description that is long enough to pass the seventy character lower bound.">
    <link rel="canonical" href="%<canonical>s"></head><body><p>Hi</p></body></html>
  HTML

  def setup
    @config = configured(environment: "staging", canonical_aliases: ["example.com"])
    @config.llms_txt.enabled = true
    @config.markdown.enabled = false
    @requests = []
    @routes = {
      "www.example.com/robots.txt" => [200, "text/plain", "User-agent: *\nDisallow: /private\n"],
      "www.example.com/sitemap.xml" => [200, "application/xml", sitemap(%w[/ /private/a /dup])],
      "www.example.com/" => [200, "text/html", page("Same", "https://www.example.com/")],
      "www.example.com/private/a" => [200, "text/html", page("Private", "https://www.example.com/private/a")],
      "www.example.com/dup" => [200, "text/html", page("Same", "https://example.com/dup")],
      "www.example.com/llms.txt" => [200, "text/plain", "# X\n\n- [Gone](https://www.example.com/gone)\n- [Other](https://other.test/x)\n"],
      "example.com/robots.txt" => [500, "text/plain", "boom"],
      "example.com/sitemap.xml" => [200, "application/xml", sitemap(%w[/])],
      "example.com/" => [200, "text/html", page("Alias", "https://www.example.com/")]
    }
  end

  def sitemap(paths)
    urls = paths.map { |path| "<url><loc>https://www.example.com#{path}</loc></url>" }.join
    %(<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">#{urls}</urlset>)
  end

  def page(title, canonical)
    format(PAGE, title: title, canonical: canonical)
  end

  def app
    lambda do |env|
      key = "#{env["HTTP_HOST"] || env["SERVER_NAME"]}#{env["PATH_INFO"]}"
      @requests << [key, env["HTTPS"], @config.environment_name]
      status, type, body = @routes.fetch(key, [404, "text/plain", "not found"])
      [status, { "content-type" => type }, [body]]
    end
  end

  def run_audit
    SeoGeo::Audit::Runner.new(app: app, config: @config, sitemap: SeoGeo::Sitemap::Registry.new).run
  end

  def checks(report, severity = :error)
    report.findings.select { |item| item.severity == severity }.map { |item| [item.check, item.url] }
  end

  def test_findings_from_canned_responses
    report = run_audit
    errors = checks(report)
    assert_includes errors, ["sitemap.robots_blocked", "https://www.example.com/private/a"]
    assert_includes errors, ["canonical", "https://www.example.com/dup"]
    assert_includes errors, ["llms.link", "https://www.example.com/gone"]
    refute(errors.any? { |_, url| url.to_s.include?("other.test") }, "links to other origins are not fetched")
    assert_includes errors, ["robots.status", "/robots.txt"]
    assert_includes errors, ["sitemap.unexpected", "/sitemap.xml"]
    assert_includes checks(report, :warning), ["title.duplicate", "https://www.example.com/"]
    assert report.errors?
  end

  def test_duplicate_descriptions_and_soft_404_for_each_host
    report = run_audit
    assert_includes checks(report, :warning), ["description.duplicate", "https://www.example.com/"]
    probes = @requests.select { |key, _| key.match?(%r{/seo-geo-audit-[0-9a-f]{16}\z}) }
    assert_equal 2, probes.size
    refute_includes report.errors.map(&:check), "page.soft_404"
    catch_all = lambda do |env|
      env["PATH_INFO"].start_with?("/seo-geo-audit-") ? [201, {}, ["catch all"]] : app.call(env)
    end
    report = SeoGeo::Audit::Runner.new(app: catch_all, config: @config).run
    assert_equal 2, report.errors.count { |finding| finding.check == "page.soft_404" }
  end

  def test_audits_as_an_indexable_environment_and_restores_it
    run_audit
    assert(@requests.all? { |_, https, env| https == "on" && env == "production" })
    assert_equal "staging", @config.environment_name
  end

  def test_max_pages_and_host_filter
    report = SeoGeo::Audit::Runner.new(app: app, config: @config, sitemap: SeoGeo::Sitemap::Registry.new,
                                       hosts: ["www.example.com"], max_pages: 1).run
    assert_equal 2, report.stats["skipped"]
    refute(@requests.any? { |key, _| key.start_with?("example.com") })
  end

  def test_exceptions_become_findings
    boom = ->(_env) { raise "kaboom\nsecond line" }
    report = SeoGeo::Audit::Runner.new(app: boom, config: @config, sitemap: SeoGeo::Sitemap::Registry.new,
                                       hosts: ["www.example.com"]).run
    assert_includes report.errors.map(&:message), "RuntimeError: kaboom"
  end

  def test_intentionally_denied_crawlers_are_not_robots_errors
    @config.crawlers.training = :deny
    @routes["www.example.com/robots.txt"] = [200, "text/plain", "User-agent: *\nAllow: /\n\nUser-agent: GPTBot\nDisallow: /\n"]
    report = SeoGeo::Audit::Runner.new(app: app, config: @config, sitemap: SeoGeo::Sitemap::Registry.new,
                                       hosts: ["www.example.com"]).run
    refute_includes report.errors.map(&:check), "sitemap.robots_blocked"
  end

  def test_markdown_checks_skip_entries_flagged_markdown_false
    @config.markdown.enabled = true
    @routes["www.example.com/"] = [200, "text/html",
                                   page("Same", "https://www.example.com/").sub("</head>", '<link rel="alternate" type="text/markdown" href="https://www.example.com/index.md"></head>')]
    run = lambda do |registry|
      SeoGeo::Audit::Runner.new(app: app, config: @config, sitemap: registry, hosts: ["www.example.com"]).run
    end
    flagged = SeoGeo::Sitemap::Registry.new.tap { |registry| registry.add "/", markdown: false }
    refute(run.call(flagged).errors.any? { |item| item.check.start_with?("markdown.") })
    assert(run.call(SeoGeo::Sitemap::Registry.new).errors.any? { |item| item.check == "markdown.url" })
  end
end
