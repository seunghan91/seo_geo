# frozen_string_literal: true

require "test_helper"
require "rails"
require "action_controller/railtie"
require "rack/mock"
require "seo_geo/engine"
require "tmpdir"
require "generators/seo_geo/install/install_generator"

# The README Troubleshooting table quotes messages verbatim (agents search for them). Each test triggers the real
# error or finding and checks that the README contains the text the gem produced.
class TroubleshootingTest < Minitest::Test
  README = File.read(File.expand_path("../../README.md", __dir__))

  def assert_documented(message)
    assert_includes README, message, "README Troubleshooting must quote this message verbatim"
  end

  def config_errors
    config = SeoGeo::Configuration.new
    yield config
    config.errors
  end

  def test_configuration_errors
    assert_documented "SeoGeo::ConfigurationError: invalid seo_geo configuration:"
    assert_includes config_errors { nil }, 'canonical_origin is required (e.g. "https://www.example.com")'
    assert_documented "- #{config_errors { nil }.first}"
    {
      ->(c) { c.canonical_origin = "https://www.example.com/en" } =>
        'canonical_origin must not contain a path, query or fragment (got "https://www.example.com/en")',
      ->(c) { c.title_template = "%{site}" } => "title_template must contain %{title}",
      ->(c) { c.og_image.permitted_params = ["theme"] } =>
        'og_image.permitted_params "theme" needs an og_image.param_constraints entry',
      ->(c) { c.indexnow.key = "robots" } => 'indexnow.key "robots" collides with another /<name>.txt route'
    }.each do |change, message|
      errors = config_errors do |config|
        config.canonical_origin = "https://www.example.com"
        change.call(config)
      end
      assert_includes errors, message
      assert_documented message
    end
  end

  def test_missing_origin_warning
    first_sentence = SeoGeo::Engine::MISSING_ORIGIN[/\A.*?\(Disallow: \/, noindex\)\./]
    refute_nil first_sentence
    assert_documented first_sentence
  end

  def test_generator_origin
    Dir.mktmpdir do |root|
      error = assert_raises(Thor::Error) do
        SeoGeo::Generators::InstallGenerator.new(["example.com"], {}, destination_root: root).validate_origin
      end
      assert_documented error.message
    end
  end

  def test_json_ld_invalid_node
    config = SeoGeo::Configuration.new.tap { |c| c.canonical_origin = "https://www.example.com" }
    error = assert_raises(SeoGeo::JsonLd::InvalidNode) do
      SeoGeo::JsonLd.new(origin: "https://www.example.com", config: config).product(name: "Widget")
    end
    assert_documented "#{error.class}: #{error.message}"
  end

  def test_unknown_seo_option
    controller = Class.new { include SeoGeo::Controller }.new
    error = assert_raises(ArgumentError) { controller.seo(titel: "Pricing") }
    assert_documented error.message
  end

  def test_missing_page
    error = assert_raises(KeyError) { SeoGeo::PageRegistry.new.fetch(:pricing, locale: :en) }
    assert_documented "KeyError: #{error.message[/\A.*? is not defined/]}"
  end

  def test_sitemap_errors
    error = assert_raises(SeoGeo::ConfigurationError) { SeoGeo::Sitemap::Registry.new.add(-> { [] }) }
    assert_documented error.message
    error = assert_raises(SeoGeo::ConfigurationError) { SeoGeo::Sitemap::Registry.new.add("pricing") }
    assert_documented error.message
  end

  def test_markdown_406
    app = SeoGeo::Markdown::PathSuffix.new(->(_env) { [200, { "content-type" => "text/html" }, ["<p>Pricing</p>"]] })
    status, _headers, body = app.call(Rack::MockRequest.env_for("https://www.example.com/pricing.md"))
    assert_equal 406, status
    assert_documented "406 `#{body.join.strip}`"
  end

  def test_audit_host_authorization
    config = SeoGeo::Configuration.new.tap { |c| c.canonical_origin = "https://www.example.com" }
    blocked = ->(_env) { [403, { "content-type" => "text/html" }, ["<h1>Blocked hosts: www.example.com</h1>"]] }
    report = SeoGeo::Audit::Runner.new(app: blocked, config: config, sitemap: SeoGeo::Sitemap::Registry.new).run
    finding = report.findings.find { |item| item.check == "host_authorization" }
    refute_nil finding
    # The message contains backticks, so the README quotes it with double backticks.
    assert_documented "`#{finding.check}`: `` #{finding.message} ``"
  end

  def test_audit_static_scan
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "public"))
      File.write(File.join(root, "public/robots.txt"), "User-agent: *\n")
      FileUtils.mkdir_p(File.join(root, "app/controllers"))
      File.write(File.join(root, "app/controllers/pages_controller.rb"),
                 "render :bot if request.user_agent.include?(\"Googlebot\")\n")
      report = SeoGeo::Audit::StaticScan.new(root).call(SeoGeo::Audit::Report.new)
      shadowing = report.findings.find { |item| item.check == "static.shadowing" }
      assert_documented "`static.shadowing`: `#{shadowing.message}`"
      branch = report.findings.find { |item| item.check == "code.user_agent_branch" }
      assert_documented "`code.user_agent_branch`: `#{branch.message[/\A.*?\(it is spoofable\)/]}`"
    end
  end

  # Raised only from a full audit run (it fetches every listed page); the literal lives in the runner.
  def test_audit_sitemap_noindex
    source = File.read(File.expand_path("../../lib/seo_geo/audit/runner.rb", __dir__))
    message = "listed in sitemap.xml but the page is noindex"
    assert_includes source, %("sitemap.noindex", "#{message}")
    assert_documented "`sitemap.noindex`: `#{message}`"
  end

  def test_undeclared_host_warning
    SeoGeo::UndeclaredHost.reset!
    config = SeoGeo::Configuration.new
    config.canonical_origin = "https://www.example.com"
    config.environment = "production"
    _, err = capture_io { SeoGeo::UndeclaredHost.warn_once("127.0.0.1", config: config) }
    assert_documented err.strip
  ensure
    SeoGeo::UndeclaredHost.reset!
  end

  def test_production_rake_warning
    assert_documented SeoGeo::Engine::PRODUCTION_TOOLING
  end

  def test_markdown_path_suffix_option
    assert SeoGeo::Configuration.new.markdown.respond_to?(:path_suffix=)
    assert_documented "seo.markdown.path_suffix = false"
  end
end
