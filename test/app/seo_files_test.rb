# frozen_string_literal: true

require "test_helper"
require "support/robots_rules"
require "nokogiri"

# /robots.txt, /sitemap.xml, /llms.txt, /llms-full.txt through the mounted engine.
class SeoFilesTest < ActionDispatch::IntegrationTest
  # Swaps in a fresh configuration + sitemap for one test (the dummy's own config is restored after).
  def setup
    @saved = %i[@config @sitemap].to_h { |name| [name, SeoGeo.instance_variable_get(name)] }
    config = SeoGeo::Configuration.new
    SeoGeoDummyBase.configure_seo_geo(config)
    config.host "www.example.com", disallow: ["/admin", "/oauth/"]
    config.host "start.example.com", disallow: ["/console"]
    config.host "api.example.com", indexable: false
    config.share_prefixes = ["/s/"]
    SeoGeo.instance_variable_set(:@config, config)
    SeoGeo.instance_variable_set(:@sitemap, SeoGeo::Sitemap::Registry.new)
    SeoGeo.sitemap.draw do
      add "/", priority: 1.0
      add "/가이드", lastmod: Date.new(2026, 10, 1)
      add "/admin/stats"
      add "/intro", hosts: ["start.example.com"]
    end
  end

  def teardown
    @saved.each { |name, value| SeoGeo.instance_variable_set(name, value) }
  end

  def robots_for(host)
    host! host
    get "/robots.txt"
    assert_response :success
    RobotsRules.new(response.body)
  end

  def test_robots_is_plain_text_and_cached
    host! "www.example.com"
    get "/robots.txt"
    assert_equal "text/plain; charset=utf-8", response.headers["Content-Type"]
    assert_includes response.headers["Cache-Control"], "max-age=3600"
    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.body, "Sitemap: https://www.example.com/sitemap.xml"
  end

  # Regression: an `Allow: /`-only GPTBot group re-opened disallowed paths.
  def test_gptbot_obeys_the_star_disallow_list
    rules = robots_for("www.example.com")
    assert_includes rules.agents, "gptbot"
    refute rules.allowed?("*", "/admin")
    refute rules.allowed?("GPTBot", "/admin/users")
    refute rules.allowed?("GPTBot", "/oauth/authorize")
    refute rules.allowed?("ClaudeBot", "/oauth/token")
    assert rules.allowed?("GPTBot", "/")
  end

  def test_robots_per_host
    start = robots_for("start.example.com")
    refute start.allowed?("GPTBot", "/console")
    assert start.allowed?("GPTBot", "/admin"), "www's disallow list must not leak onto start"
    assert_includes response.body, "Sitemap: https://start.example.com/sitemap.xml"

    api = robots_for("api.example.com")
    refute api.allowed?("Googlebot", "/")
    assert api.allowed?("Googlebot", "/.well-known/assetlinks.json")
    refute_includes response.body, "Sitemap:"
  end

  def test_unknown_host_fails_closed_but_well_known_and_share_links_stay_open
    rules = robots_for("preview-123.onrender.com")
    refute rules.allowed?("Googlebot", "/")
    refute rules.allowed?("GPTBot", "/about")
    assert rules.allowed?("Googlebot", "/.well-known/assetlinks.json")
    assert rules.allowed?("facebookexternalhit", "/s/abc")
  end

  def test_non_production_disallows_everything
    SeoGeo.config.environment = "staging"
    rules = robots_for("www.example.com")
    refute rules.allowed?("Googlebot", "/")
    refute_includes response.body, "Sitemap:"
    host! "www.example.com"
    get "/sitemap.xml"
    assert_response :not_found
  end

  def test_sitemap_xml
    host! "www.example.com"
    get "/sitemap.xml"
    assert_response :success
    assert_equal "application/xml; charset=utf-8", response.headers["Content-Type"]
    assert_includes response.headers["Cache-Control"], "max-age=3600"
    document = Nokogiri::XML(response.body, &:strict)
    assert_equal "urlset", document.root.name
    assert_equal ["https://www.example.com/", "https://www.example.com/%EA%B0%80%EC%9D%B4%EB%93%9C"],
                 document.xpath("//*[local-name()='loc']").map(&:text)
    assert_equal ["2026-10-01"], document.xpath("//*[local-name()='lastmod']").map(&:text)
  end

  def test_sitemap_per_host_and_404s
    host! "start.example.com"
    get "/sitemap.xml"
    assert_response :success
    assert_includes response.body, "<loc>https://start.example.com/intro</loc>"

    %w[api.example.com example.com unknown.example.net].each do |host|
      host! host
      get "/sitemap.xml"
      assert_response :not_found, host
    end

    host! "www.example.com"
    get "/sitemap-1.xml"
    assert_response :not_found
  end

  def test_sitemap_index_above_50_000
    SeoGeo.sitemap.add Array.new(50_001) { |n| n }, path: ->(n) { "/n/#{n}" }
    host! "www.example.com"
    get "/sitemap.xml"
    assert_response :success
    index = Nokogiri::XML(response.body, &:strict)
    assert_equal "sitemapindex", index.root.name
    assert_equal %w[https://www.example.com/sitemap-1.xml https://www.example.com/sitemap-2.xml],
                 index.xpath("//*[local-name()='loc']").map(&:text)
    get "/sitemap-2.xml" # 2 static URLs + 50,001 => 50,000 + 3
    assert_response :success
    assert_equal 3, Nokogiri::XML(response.body, &:strict).xpath("//*[local-name()='url']").length
    get "/sitemap-3.xml"
    assert_response :not_found
  end

  def test_llms_txt
    SeoGeo.config.llms_txt.page :home, path: "/"
    SeoGeo.config.llms_txt.link "Privacy", "/privacy", optional: true
    host! "www.example.com"
    get "/llms.txt"
    assert_response :success
    assert_equal "text/plain; charset=utf-8", response.headers["Content-Type"]
    assert_includes response.headers["Cache-Control"], "max-age=3600"
    assert_equal <<~TXT, response.body
      # Dummy

      > A dummy application for seo_geo tests.

      ## Pages

      - [Dummy home](https://www.example.com/index.md): The home page of the dummy application.

      ## Optional

      - [Privacy](https://www.example.com/privacy)
    TXT

    get "/llms-full.txt"
    assert_response :success
    assert_includes response.body, "Source: https://www.example.com/\n\n## Welcome to Dummy"
    assert_includes response.body, "#### Is this real?\n\nIt is a test fixture."

    host! "api.example.com"
    get "/llms.txt"
    assert_response :not_found
  end

  # A proxy that drops Host would deindex the site silently; robots.txt logs the undeclared host once.
  def test_robots_txt_logs_an_undeclared_host_once
    SeoGeo::UndeclaredHost.reset!
    io = StringIO.new
    saved = Rails.logger
    Rails.logger = Logger.new(io)
    host! "127.0.0.1"
    2.times { get "/robots.txt" }
    assert_includes response.body, "Disallow: /"
    assert_equal 1, io.string.scan('seo_geo: host "127.0.0.1" is not declared').size
  ensure
    Rails.logger = saved
    SeoGeo::UndeclaredHost.reset!
  end
end

