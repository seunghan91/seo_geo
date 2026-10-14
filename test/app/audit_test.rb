# frozen_string_literal: true

require "test_helper"
require "seo_geo/testing"
require "rake"
require "stringio"

# rake seo_geo:audit and the Minitest assertions against the real engine + dummy app.
class AuditTest < ActionDispatch::IntegrationTest
  include SeoGeo::Testing::Assertions

  def setup
    @saved = %i[@config @sitemap].to_h { |name| [name, SeoGeo.instance_variable_get(name)] }
    config = SeoGeo::Configuration.new
    SeoGeoDummyBase.configure_seo_geo(config)
    config.host "www.example.com", disallow: ["/admin"]
    config.verification.google = "g-token"
    SeoGeo.instance_variable_set(:@config, config)
    SeoGeo.instance_variable_set(:@sitemap, SeoGeo::Sitemap::Registry.new)
  end

  def teardown
    @saved.each { |name, value| SeoGeo.instance_variable_set(name, value) }
  end

  def audit(&block)
    SeoGeo.sitemap.draw(&block)
    SeoGeo::Audit::Runner.new(app: Rails.application, root: Rails.root).run
  end

  def errors(report)
    report.errors.map { |item| [item.check, item.url.to_s.delete_prefix("https://www.example.com")] }
  end

  def test_audit_reports_the_problems_a_crawler_would_hit
    report = audit do
      add "/"
      add "/audit_pages/markdown", markdown: true
      add "/audit_pages/hidden_faq"
      add "/head_pages/noindex"
    end
    found = errors(report)
    assert_includes found, ["sitemap.noindex", "/head_pages/noindex"]
    assert_includes found, ["faq.visible", "/audit_pages/hidden_faq"]
    # The head advertises Markdown only for Markdownable actions, so no Markdown check fails.
    refute(found.any? { |check, _| check.start_with?("markdown.") }, report.to_s)
    refute(found.any? { |_, url| url.start_with?("/audit_pages/markdown") }, report.to_s)
    refute(found.any? { |check, _| %w[canonical title.count json_ld verification robots.status llms.link].include?(check) }, report.to_s)
    assert_operator report.stats["pages"], :>=, 5
  end

  def test_a_clean_site_has_no_errors
    SeoGeo.config.markdown.enabled = false
    SeoGeo.config.environment = "development" # audited as production, then restored
    report = audit do
      add "/"
      add "/head_pages/indexed"
    end
    assert_empty report.errors, report.to_s
    assert_equal "development", SeoGeo.config.environment_name
    assert_equal 1, report.stats["audited as production"]
  end

  def test_declared_noindex_paths_leave_the_sitemap_and_get_robots_noindex
    SeoGeo.config.noindex_paths = ["/head_pages/indexed"]
    report = audit do
      add "/"
      add "/head_pages/indexed"
      add "/audit_pages/markdown", noindex: true
    end
    assert_equal ["https://www.example.com/"], assert_seo_geo_sitemap(host: "www.example.com")
    get "/head_pages/indexed"
    assert_includes response.body, "noindex"
    get "/audit_pages/markdown"
    assert_includes response.body, "noindex"
    get "/llms.txt"
    refute_includes response.body, "/head_pages/indexed"
    refute(errors(report).any? { |check, _| check == "sitemap.noindex" }, report.to_s)
  end

  # .md links in llms.txt are served by Markdown::PathSuffix; entries for non-Markdownable actions must say
  # markdown: false, and the audit catches the ones that do not.
  def test_llms_markdown_links_are_checked
    SeoGeo.config.llms_txt.page :home, path: "/"                                      # PagesController: not markdownable
    SeoGeo.config.llms_txt.link "Markdown page", "/audit_pages/markdown", markdown: true   # markdownable
    report = audit { add "/" }
    found = errors(report)
    assert_includes found, ["llms.link", "/index.md"], report.to_s
    refute(found.any? { |_, url| url.start_with?("/audit_pages/markdown") }, report.to_s)

    SeoGeo.config.llms_txt.links.clear
    SeoGeo.config.llms_txt.page :home, path: "/", markdown: false
    SeoGeo.sitemap.clear
    refute(errors(audit { add "/" }).any? { |check, _| check.start_with?("llms.") })
  end

  def test_rake_task_prints_json_and_exits_non_zero_on_errors
    Rails.application.load_tasks unless Rake::Task.task_defined?("seo_geo:audit")
    SeoGeo.sitemap.add "/head_pages/noindex"
    out = StringIO.new
    status = nil
    ENV["FORMAT"] = "json"
    begin
      $stdout = out
      Rake::Task["seo_geo:audit"].reenable
      Rake::Task["seo_geo:audit"].invoke
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = STDOUT
      ENV.delete("FORMAT")
    end
    assert_equal 1, status
    json = JSON.parse(out.string)
    assert_includes json["findings"].map { |item| item["check"] }, "sitemap.noindex"
  end

  def test_minitest_assertions
    assert_seo_geo_canonical "/", host: "example.com", expected: "https://www.example.com/"
    assert_seo_geo_canonical "/audit_pages/markdown?utm_source=x", host: "www.example.com"
    assert_seo_geo_single_title "/", host: "www.example.com"
    assert_seo_geo_faq_matches_visible "/"
    SeoGeo.sitemap.add "/"
    assert_equal ["https://www.example.com/"], assert_seo_geo_sitemap(host: "www.example.com")
    assert_seo_geo_no_sitemap host: "example.com"
    assert_seo_geo_no_sitemap host: "preview.onrender.com"
    refute_seo_geo_robots_allows "GPTBot", "/admin", host: "www.example.com"
    assert_seo_geo_robots_allows "Mozilla/5.0 (compatible; GPTBot/1.2)", "/pricing", host: "www.example.com"
    assert_seo_geo_robots_allows "Googlebot", "/.well-known/assetlinks.json", host: "unknown.example.org"

    failure = assert_raises(Minitest::Assertion) { assert_seo_geo_faq_matches_visible "/audit_pages/hidden_faq" }
    assert_includes failure.message, "Secret question?"
    assert_raises(Minitest::Assertion) { assert_seo_geo_canonical "/", host: "example.com", expected: "https://example.com/" }
    assert_raises(Minitest::Assertion) { assert_seo_geo_robots_allows "GPTBot", "/admin", host: "www.example.com" }
  end
end
