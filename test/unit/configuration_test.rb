# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    SeoGeo.reset!
  end

  def test_defaults
    config = SeoGeo::Configuration.new
    assert_nil config.canonical_origin
    assert_equal :fail_closed, config.unknown_host
    assert_equal ["/.well-known/"], config.allow_exceptions
    assert_equal ["production"], config.indexable_environments
    assert_equal "%{title} | %{site}", config.title_template
    assert_equal 160, config.description_max_length
    assert_equal false, config.default_noindex
    assert_equal 3600, config.cache_control_seconds
    assert_equal :en, config.site.default_locale
    assert_equal [], config.site.same_as
    assert_equal %i[allow allow allow], [config.crawlers.training, config.crawlers.search, config.crawlers.user]
    assert_equal false, config.aipref.enabled
    assert_equal true, config.markdown.enabled
    assert_equal :reverse_markdown, config.markdown.converter
    assert_equal "https://api.indexnow.org/indexnow", config.indexnow.endpoint
    assert_equal false, config.indexnow.enabled
    assert_nil config.indexnow.dry_run
    assert_equal 10_000, config.indexnow.batch_size
    assert_equal [1200, 630], [config.og_image.width, config.og_image.height]
    assert_equal "1", config.og_image.template_version
    assert_equal [604_800, 2, 100, [], {}], [config.og_image.cache_ttl, config.og_image.max_concurrent,
                                              config.og_image.max_param_length, config.og_image.keys,
                                              config.og_image.param_constraints]
    assert_nil config.og_image.key_resolver
  end

  def test_configure_yields_the_singleton
    returned = SeoGeo.configure { |c| c.site.name = "Acme" }
    assert_same SeoGeo.config, returned
    assert_equal "Acme", SeoGeo.config.site.name
  end

  def test_minimal_configuration_is_valid
    assert_same configured.validate!.class, SeoGeo::Configuration
  end

  def test_canonical_origin_is_required
    error = assert_raises(SeoGeo::ConfigurationError) { SeoGeo::Configuration.new.validate! }
    assert_includes error.message, "canonical_origin is required"
  end

  def test_canonical_origin_shape
    assert_includes configured(canonical_origin: "www.example.com").errors.join, "absolute http(s) URL"
    assert_includes configured(canonical_origin: "https://example.com/app").errors.join, "must not contain a path"
    assert_equal "https://example.com", configured(canonical_origin: "https://example.com/").canonical_origin
  end

  def test_validate_lists_every_problem
    config = configured do |c|
      c.title_template = "%{site}"
      c.description_max_length = 10
      c.cache_control_seconds = -1
      c.crawlers.training = :maybe
      c.crawlers.override("Bytespider", :block)
      c.indexnow.enabled = true
      c.indexnow.key = "short"
      c.og_image.backend = "not callable"
      c.og_image.width = 0
      c.share_prefixes = ["s/"]
      c.unknown_host = :open
      c.hreflang_url = "x"
    end
    error = assert_raises(SeoGeo::ConfigurationError) { config.validate! }
    [
      "title_template must contain %{title}", "description_max_length", "cache_control_seconds",
      "crawlers.training must be :allow or :deny", "crawlers.override(\"Bytespider\")", "indexnow.key",
      "og_image.backend", "og_image.width", "\"s/\" must start with /", "unknown_host", "hreflang_url"
    ].each { |fragment| assert_includes error.message, fragment }
  end

  def test_locale_validation
    config = configured(locales: %i[ko ja], x_default_locale: :en)
    messages = config.errors.join("\n")
    assert_includes messages, "site.default_locale :en must be listed in locales"
    assert_includes messages, "x_default_locale :en must be listed in locales"
    assert_equal :ko, configured(locales: %i[en ko], x_default_locale: :ko).effective_x_default_locale
    assert_equal :en, configured(locales: %i[en ko]).effective_x_default_locale
    assert_nil configured.effective_x_default_locale
  end

  def test_host_rejects_paths
    assert_raises(SeoGeo::ConfigurationError) { configured.host("example.com/admin") }
    config = configured { |c| c.host "www.example.com", disallow: ["admin"] }
    assert_includes config.errors.join, "must start with /"
  end

  def test_environment_gate
    config = configured(environment: "staging")
    refute config.indexable_environment?
    config.environment = -> { "production" }
    assert config.indexable_environment?
  end

  def test_title_and_description
    config = configured { |c| c.site.name = "Acme" }
    assert_equal "Pricing | Acme", config.format_title("Pricing")
    assert_equal "Acme", config.format_title("Acme")
    assert_equal "Pricing", configured.format_title("Pricing")
    long = "word " * 60
    truncated = config.truncate_description(long)
    assert_operator truncated.length, :<=, 160
    assert truncated.end_with?("…")
    refute_match(/\s…\z/, truncated)
    assert_equal "short text", config.truncate_description("  short \n text ")
    assert_nil config.truncate_description(nil)
  end

  def test_content_signal_derives_from_crawler_policy
    config = configured { |c| c.crawlers.training = :deny }
    assert_equal "search=yes, ai-input=yes, ai-train=no", config.content_signal_value
    assert_nil config.content_usage_value
    config.aipref.enabled = true
    assert_equal "train-ai=n, search=y", config.content_usage_value
    config.content_signal = { search: false, ai_input: false, ai_train: true }
    assert_equal "search=no, ai-input=no, ai-train=yes", config.content_signal_value
  end

  def test_verification_meta_tags_skip_blank_values
    config = configured
    config.verification.google = "g-token"
    config.verification.naver = ""
    config.verification.daum_pin = "1234"
    assert_equal({ "google-site-verification" => "g-token" }, config.verification.meta_tags)
  end

  def test_ferrum_detection_does_not_raise
    assert_includes [true, false], configured.og_image.ferrum_available?
  end

  def test_llms_txt_defaults_and_links
    llms = configured.llms_txt
    assert_equal [true, true, nil, "Pages", []], [llms.enabled, llms.full, llms.details, llms.default_section, llms.links]
    llms.page :home, path: "/", hosts: "www.example.com"
    llms.link "Terms", "/terms", optional: true
    assert_equal [:home, nil], llms.links.map(&:page)
    assert_equal [["www.example.com"], nil], llms.links.map(&:hosts)
  end

  def test_llms_txt_link_must_be_a_path_or_url
    config = configured
    config.llms_txt.link "Docs", "https://docs.example.com/"
    assert_empty config.errors
    config.llms_txt.link "Bad", "terms"
    assert_includes config.errors, 'llms_txt link "terms" must be a path starting with / or an http(s) URL'
  end

  # keys
  def test_markdown_indexnow_og_defaults
    config = configured
    assert_equal "main, [role=main]", config.markdown.selector
    assert_equal [], config.og_image.permitted_params
    assert_nil config.og_image.template
    assert_empty config.errors
  end

  # keys
  def test_noindex_paths_default_and_validation
    config = configured
    assert_equal [], config.noindex_paths
    refute config.noindex_path?("/")
    config.noindex_paths = ["/waitlist", %r{\A/drafts/}, "relative", 42]
    assert config.noindex_path?("/waitlist?ref=x")
    assert config.noindex_path?("https://www.example.com/drafts/1")
    refute config.noindex_path?("/waitlist/more")
    assert_includes config.errors, 'noindex_paths entry "relative" must be a path String starting with / or a Regexp'
    assert_includes config.errors, "noindex_paths entry 42 must be a path String starting with / or a Regexp"
  end
end
