# frozen_string_literal: true

require "test_helper"
require "support/audit_http_stub"
require "support/audit_http_server"
require "open3"
require "rbconfig"
require "stringio"

class AuditRemoteTest < Minitest::Test
  DESCRIPTION = "A complete description of this public page, long enough to satisfy the audit checks."

  def run
    Net::HTTP.stub(:new, ->(host, port, proxy) { (@servers&.fetch([host, port], nil) || @server).connection(host, port, proxy) }) { super }
  end

  def setup
    @overrides = {}
    @server = AuditHttpStub.new do |path, headers, origin|
      custom = @overrides[path] || (path.start_with?("/seo-geo-audit-") && @overrides[:missing])
      next custom.call(headers, origin) if custom.respond_to?(:call)
      next custom if custom

      case path
      when "/robots.txt" then [200, { "Content-Type" => "text/plain" }, "User-agent: *\nAllow: /\n"]
      when "/sitemap.xml"
        [200, { "Content-Type" => "application/xml" }, %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>#{origin}/</loc></url></urlset>)]
      when "/llms.txt" then [200, { "Content-Type" => "text/plain" }, "# Site"]
      when "/" then [200, { "Content-Type" => "text/html" }, page(origin)]
      else [404, { "Content-Type" => "text/plain" }, "Missing"]
      end
    end
  end

  def teardown
    @server&.close
  end

  def page(origin, title: "Home")
    %(<html lang="en"><head><title>#{title}</title><meta name="description" content="#{DESCRIPTION}"><link rel="canonical" href="#{origin}/"></head><body><main>Home</main></body></html>)
  end

  def audit(urls = [@server.origin], **options)
    SeoGeo::Audit::Remote.run(urls, io: nil, config: nil, delay: 0, **options)
  end

  def test_normal_remote_report_and_request_identity
    report = audit
    assert_empty report.findings, report.to_s
    assert_equal 1, report.stats["pages"]
    assert(@server.connections.all? { |connection| connection.open_timeout == 10 && connection.read_timeout == 10 && connection.write_timeout == 10 && connection.max_retries == 0 })
    assert_equal 1, @server.requests.count { |r| r[:path].match?(%r{\A/seo-geo-audit-[0-9a-f]{16}\z}) }
    assert(@server.requests.all? { |r| r[:headers]["user-agent"] == "seo_geo-audit/#{SeoGeo::VERSION}" })
  end

  def test_multiple_origins_share_request_pacing_and_keep_their_ports
    second = AuditHttpStub.new(origin: "http://127.0.0.1:18081") do |path, _, origin|
      case path
      when "/robots.txt" then [200, {}, "User-agent: *\nAllow: /\n"]
      when "/sitemap.xml"
        [200, {}, %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>#{origin}/</loc></url></urlset>)]
      when "/llms.txt" then [200, {}, "# Site"]
      when "/" then [200, { "Content-Type" => "text/html" }, page(origin)]
      else [404, {}, "Missing"]
      end
    end
    @servers = { ["127.0.0.1", 18081] => second }
    report = SeoGeo::Audit::Remote.run([@server.origin, second.origin], io: nil, config: nil, delay: 0.01)
    assert_empty report.findings, report.to_s
    assert_equal 2, report.stats["pages"]
    assert_operator second.requests.first[:time] - @server.requests.last[:time], :>=, 0.01
    assert_equal 5, second.requests.size
  end

  def test_x_robots_header_even_on_an_unlisted_explicit_page
    @overrides["/hidden"] = ->(_, origin) { [200, { "Content-Type" => "text/html", "X-Robots-Tag" => "googlebot: none" }, page(origin)] }
    report = audit(["#{@server.origin}/hidden"])
    assert_includes report.errors.map(&:check), "page.x_robots_noindex"
    refute_includes report.warnings.map(&:check), "description.duplicate"
  end

  def test_soft_404_includes_any_success_status
    @overrides[:missing] = [204, {}, ""]
    assert_includes audit.errors.map(&:check), "page.soft_404"
  end

  def test_redirect_chain_preserves_first_status_and_checks_final_headers
    @overrides["/one"] = [301, { "Location" => "/two" }, ""]
    @overrides["/two"] = [302, { "Location" => "/end" }, ""]
    @overrides["/end"] = ->(_, origin) { [200, { "X-Robots-Tag" => "noindex", "Content-Type" => "text/html" }, page(origin)] }
    report = audit(["#{@server.origin}/one"])
    finding = report.warnings.find { |f| f.check == "page.redirect_chain" }
    assert_match(/2 redirect hops/, finding.message)
    assert_match(/301 .*one -> 302 .*two -> 200 .*end/, finding.message)
    assert report.warnings.any? { |f| f.check == "page.status" && f.message.start_with?("returned 301") }
    assert_includes report.errors.map(&:check), "page.x_robots_noindex"
  end

  def test_one_hop_is_not_a_chain_warning
    @overrides["/one"] = [301, { "Location" => "/" }, ""]
    refute_includes audit(["#{@server.origin}/one"]).warnings.map(&:check), "page.redirect_chain"
  end

  def test_redirect_loop_and_limit_are_bounded
    @overrides["/loop"] = [302, { "Location" => "/loop" }, ""]
    assert_includes audit(["#{@server.origin}/loop"]).errors.map(&:check), "page.redirect"
    7.times { |i| @overrides["/hop#{i}"] = [302, { "Location" => "/hop#{i + 1}" }, ""] }
    report = audit(["#{@server.origin}/hop0"])
    assert report.errors.any? { |f| f.check == "page.redirect" && f.message.include?("5 hops") }
    assert_equal 6, @server.requests.count { |r| r[:path].start_with?("/hop") }
  end

  def test_robots_comparison_only_for_a_known_host_without_config_mutation
    config = configured(environment: "staging")
    report = SeoGeo::Audit::Remote.run([@server.origin], io: nil, config: config, delay: 0)
    refute_includes report.warnings.map(&:check), "robots.mismatch"
    config.canonical_origin = @server.origin
    config.environment = "production"
    report = SeoGeo::Audit::Remote.run([@server.origin], io: nil, config: config, delay: 0)
    assert_includes report.warnings.map(&:check), "robots.mismatch"
    assert_equal "production", config.environment
    @overrides["/robots.txt"] = [200, {}, SeoGeo::Robots.new(config, "127.0.0.1").to_s]
    report = SeoGeo::Audit::Remote.run([@server.origin], io: nil, config: config, delay: 0)
    refute_includes report.warnings.map(&:check), "robots.mismatch"
  end

  # 문서가 안내하는 비교 경로 — 개발 환경 config 로 라이브 사이트를 볼 때도 production 기준으로
  # 판정하고, 끝나면 환경을 되돌린다 (advisor 리뷰: 오버라이드가 이 전환을 꺼 거짓 오류를 냈다).
  def test_remote_comparison_from_development_config_judges_as_production_and_restores
    config = configured(environment: "development")
    config.canonical_origin = @server.origin
    production_robots = begin
      config.environment = "production"
      SeoGeo::Robots.new(config, "127.0.0.1").to_s
    ensure
      config.environment = "development"
    end
    @overrides["/robots.txt"] = [200, {}, production_robots]
    report = SeoGeo::Audit::Remote.run([@server.origin], io: nil, config: config, delay: 0)
    refute_includes report.warnings.map(&:check), "robots.mismatch"
    refute_includes report.errors.map(&:check), "sitemap.unexpected"
    assert_equal "development", config.environment
  end

  def test_shared_checks_markdown_and_duplicate_descriptions
    @overrides["/other"] = ->(_, origin) { [200, { "Content-Type" => "text/html" }, page(origin, title: "Other")] }
    report = audit([@server.origin, "#{@server.origin}/other"])
    assert_includes report.warnings.map(&:check), "description.duplicate"
    refute_includes report.warnings.map(&:check), "title.duplicate"
    @overrides["/"] = lambda do |headers, origin|
      if headers["accept"] == "text/markdown"
        [200, { "Content-Type" => "text/markdown" }, "# Home"]
      else
        [200, { "Content-Type" => "text/html" }, page(origin).sub("</head>", %(<link rel="alternate" type="text/markdown" href="#{origin}/index.md"></head>))]
      end
    end
    @overrides["/index.md"] = [200, { "Content-Type" => "text/markdown" }, "# Home"]
    assert_includes audit.errors.map(&:check), "markdown.vary"
  end

  def test_delay_timeout_and_bad_targets
    fetcher = SeoGeo::Audit::HttpFetcher.new(origin: @server.origin, delay: 0.02)
    2.times { fetcher.fetch("127.0.0.1", "/") }
    assert_operator @server.requests.last[:time] - @server.requests.first[:time], :>=, 0.02
    assert_raises(ArgumentError) { audit(["file:///tmp/test"]) }
    assert_raises(ArgumentError) { audit(["http://user:secret@127.0.0.1/"]) }
    @overrides["/slow"] = ->(_, _) { sleep 0.05; [200, {}, ""] }
    impatient = SeoGeo::Audit::HttpFetcher.new(origin: @server.origin, delay: 0, timeout: 0.01)
    assert_raises(Net::ReadTimeout) { impatient.fetch("127.0.0.1", "/slow") }
  end

  def test_standalone_rake_without_rails_environment_and_json_output
    out, err, status = Open3.capture3({ "URL" => @server.origin, "URLS" => nil, "FORMAT" => "json" },
                                     RbConfig.ruby, "-r", File.expand_path("../support/audit_cli_stub", __dir__), "-S", "rake", "seo_geo:audit")
    assert status.success?, "#{out}\n#{err}"
    assert_equal 0, JSON.parse(out).fetch("errors")
    @overrides[:missing] = [200, {}, ""]
    out, err, status = Open3.capture3({ "URL" => @server.origin, "URLS" => nil, "FORMAT" => nil, "AUDIT_STUB_SOFT_404" => "1" },
                                     RbConfig.ruby, "-r", File.expand_path("../support/audit_cli_stub", __dir__), "-S", "rake", "seo_geo:audit")
    assert_equal 1, status.exitstatus, err
    assert_includes out, "page.soft_404"
  end
end

# Real loopback transport coverage when sockets are permitted (sandboxed runs use the tests above).
class AuditHttpSocketTest < Minitest::Test
  def test_real_loopback_response
    server = AuditHttpServer.new { |_, _, _| [200, { "Content-Type" => "text/plain" }, "loopback"] }
    response = SeoGeo::Audit::HttpFetcher.new(origin: server.origin, delay: 0).fetch("127.0.0.1", "/")
    assert_equal 200, response.status
    assert_equal "loopback", response.body
  rescue Errno::EPERM, Errno::EACCES => e
    skip "loopback sockets unavailable: #{e.message}"
  ensure
    server&.close
  end
end
