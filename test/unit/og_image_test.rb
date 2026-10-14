# frozen_string_literal: true

require "test_helper"

class OgImageTest < Minitest::Test
  PNG = "\x89PNG\r\n\x1A\nbytes".b

  # Hash-backed stand-in for Rails.cache.
  class Cache
    attr_reader :store, :options

    def initialize
      @store = {}
      @options = []
    end

    def fetch(key, **options)
      @options << options
      @store.fetch(key) { @store[key] = yield }
    end
  end

  def test_backend_result_is_cached_by_version_key_locale_and_params
    calls = 0
    config = configured { |c| c.og_image.backend = ->(*) { calls += 1; PNG } }
    page = SeoGeo::Page.from_hash(:home, { title: "T" }, locale: :ko)
    cache = Cache.new
    2.times { SeoGeo::OgImage.render("home", page: page, params: { "a" => "1" }, config: config, cache: cache) }
    SeoGeo::OgImage.render("home", page: page, params: { "a" => "2" }, config: config, cache: cache)
    assert_equal 2, calls
    assert(cache.store.keys.all? { |key| key.start_with?("seo_geo/og/1/home/ko/") })
  end

  def test_rejects_non_png
    config = configured { |c| c.og_image.backend = ->(*) { "GIF89a" } }
    assert_raises(SeoGeo::OgImage::RenderError) { SeoGeo::OgImage.render("home", config: config, cache: nil) }
  end

  def test_no_backend_without_ferrum
    config = configured
    config.og_image.stub(:ferrum_available?, false) do
      error = assert_raises(SeoGeo::OgImage::RenderError) { SeoGeo::OgImage.render("home", config: config, cache: nil) }
      assert_includes error.message, "ferrum"
    end
  end

  def test_ferrum_template_escapes_copy
    config = configured { |c| c.site.name = "Acme & Co" }
    page = SeoGeo::Page.from_hash(:home, { title: "<b>T</b>", description: "한국어 설명" })
    html = SeoGeo::OgImage::FerrumBackend.new(config: config).html("home", page, {})
    assert_includes html, "&lt;b&gt;T&lt;/b&gt;"
    assert_includes html, "Acme &amp; Co"
    assert_includes html, "width: 1200px; height: 630px"
    assert_includes html, "word-break: keep-all"
  end

  def test_ferrum_renders_png_when_chrome_is_available
    config = configured
    skip "ferrum gem not installed" unless config.og_image.ferrum_available?
    skip "set SEO_GEO_FERRUM=1 to run the Chrome screenshot test" unless ENV["SEO_GEO_FERRUM"]

    png = SeoGeo::OgImage::FerrumBackend.new(config: config).call("home", nil, {})
    assert png.b.start_with?(SeoGeo::OgImage::PNG_SIGNATURE)
  end

  def test_og_configuration_errors
    assert_equal [], configured.og_image.permitted_params
    config = configured { |c| c.og_image.permitted_params = "theme" }
    assert_includes config.errors, "og_image.permitted_params must be an Array"
    config = configured { |c| c.og_image.template = "/nonexistent/card.erb" }
    assert_includes config.errors.join, "og_image.template"
  end

  def test_cache_entries_expire_after_cache_ttl
    config = configured { |c| c.og_image.backend = ->(*) { PNG } }
    cache = Cache.new
    SeoGeo::OgImage.render("home", config: config, cache: cache)
    assert_equal [{ expires_in: 7 * 24 * 60 * 60 }], cache.options
    config.og_image.cache_ttl = 60
    SeoGeo::OgImage.render("home", config: config, cache: cache)
    assert_equal({ expires_in: 60 }, cache.options.last)
  end

  def test_concurrent_renders_are_bounded_and_never_queue
    config = configured { |c| c.og_image.max_concurrent = 1 }
    nested = nil
    config.og_image.backend = lambda do |*|
      nested = assert_raises(SeoGeo::OgImage::Busy) { SeoGeo::OgImage.render("other", config: config, cache: nil) }
      PNG
    end
    assert_equal PNG, SeoGeo::OgImage.render("home", config: config, cache: nil)
    assert_kind_of SeoGeo::OgImage::Busy, nested
    assert_equal 0, SeoGeo::OgImage.active_renders, "slot released"
    config.og_image.backend = ->(*) { raise "boom" }
    assert_raises(RuntimeError) { SeoGeo::OgImage.render("home", config: config, cache: nil) }
    assert_equal 0, SeoGeo::OgImage.active_renders, "slot released after a failure"
  end

  def test_cache_hit_needs_no_render_slot
    config = configured { |c| c.og_image.backend = ->(*) { PNG } }
    cache = Cache.new
    SeoGeo::OgImage.render("home", config: config, cache: cache)
    SeoGeo::OgImage.stub(:active_renders, 99) do
      assert_equal PNG, SeoGeo::OgImage.render("home", config: config, cache: cache)
    end
  end

  def test_only_registered_allowlisted_or_resolved_keys
    SeoGeo.reset!
    SeoGeo.pages.register(:pricing, title: "Pricing")
    config = configured { |c| c.og_image.keys = [:promo] }
    assert SeoGeo::OgImage.resolve_key("pricing", config)
    assert SeoGeo::OgImage.resolve_key("promo", config)
    assert_nil SeoGeo::OgImage.resolve_key("random-123", config)
    page = SeoGeo::Page.from_hash(:post, { title: "Post" })
    config.og_image.key_resolver = ->(key) { page if key == "post-1" }
    assert_same page, SeoGeo::OgImage.resolve_key("post-1", config)
    assert_nil SeoGeo::OgImage.resolve_key("post-2", config)
  ensure
    SeoGeo.reset!
  end

  def test_params_must_satisfy_their_constraint_and_length_cap
    config = configured do |c|
      c.og_image.permitted_params = %w[theme title]
      c.og_image.param_constraints = { "theme" => %w[dark light], title: /[\w ]{1,40}/ }
      c.og_image.max_param_length = 20
    end
    validate = ->(query) { SeoGeo::OgImage.validated_params(query, config) }
    assert_equal({ "theme" => "dark", "title" => "Hello" }, validate.call("theme" => "dark", "title" => "Hello", "junk" => "x"))
    assert_equal({}, validate.call({}))
    assert_nil validate.call("theme" => "blue")
    assert_nil validate.call("title" => "Hello!"), "regexp must match the whole value"
    assert_nil validate.call("title" => "a" * 21), "max_param_length"
    assert_nil validate.call("theme" => ["dark"])
  end

  def test_og_flood_configuration_defaults_and_errors
    og = configured.og_image
    assert_equal [{}, 100, [], nil, 604_800, 2], [og.param_constraints, og.max_param_length, og.keys, og.key_resolver, og.cache_ttl, og.max_concurrent]
    config = configured do |c|
      c.og_image.permitted_params = %w[theme]
      c.og_image.cache_ttl = 0
      c.og_image.max_concurrent = nil
      c.og_image.key_resolver = "nope"
      c.og_image.keys = "home"
    end
    errors = config.errors.join("\n")
    assert_includes errors, 'og_image.permitted_params "theme" needs an og_image.param_constraints entry'
    assert_includes errors, "og_image.cache_ttl must be a positive Integer"
    assert_includes errors, "og_image.max_concurrent must be a positive Integer"
    assert_includes errors, "og_image.key_resolver must respond to #call"
    assert_includes errors, "og_image.keys must be an Array"
    config = configured { |c| c.og_image.param_constraints = { "theme" => [] } }
    assert_includes config.errors.join, "must be a Regexp or a non-empty Array"
  end
end
