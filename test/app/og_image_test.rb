# frozen_string_literal: true

require "test_helper"

class OgImageAppTest < ActionDispatch::IntegrationTest
  PNG = "\x89PNG\r\n\x1A\n".b + "fake-image-bytes".b

  def setup
    @og = SeoGeo.config.og_image
    @saved = { backend: @og.backend, fallback_url: @og.fallback_url, permitted_params: @og.permitted_params,
               template_version: @og.template_version, param_constraints: @og.param_constraints, keys: @og.keys,
               key_resolver: @og.key_resolver, max_concurrent: @og.max_concurrent, max_param_length: @og.max_param_length }
    @calls = []
    @cache = ActiveSupport::Cache::MemoryStore.new
    @previous_cache = Rails.cache
    Rails.cache = @cache
  end

  def teardown
    @saved.each { |name, value| @og.public_send("#{name}=", value) }
    Rails.cache = @previous_cache
  end

  def fake_backend
    calls = @calls
    ->(key, page, params) { calls << [key, page&.title, params]; PNG }
  end

  def test_renders_png_with_page_and_permitted_params
    @og.backend = fake_backend
    @og.permitted_params = %w[theme]
    @og.param_constraints = { "theme" => %w[dark light] }
    get "/og/home.png", params: { theme: "dark", junk: "x", locale: "ko" }
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal PNG, response.body.b
    assert_equal "max-age=3600, public", response.headers["Cache-Control"]
    assert_equal [["home", "더미 홈", { "theme" => "dark" }]], @calls
  end

  # an unknown key is not the engine's — it falls through to the app's /og/:username.png.
  def test_unknown_key_falls_through_to_the_app_without_rendering_or_caching
    @og.backend = fake_backend
    @og.fallback_url = "https://cdn.example.com/og-default.png"
    get "/og/custom-card.png"
    assert_response :success
    assert_equal "app og custom-card", response.body
    assert_empty @calls
    assert_equal 0, @cache.instance_variable_get(:@data).size
  end

  def test_allowlisted_and_resolved_keys_render
    @og.backend = fake_backend
    @og.keys = %w[custom-card]
    get "/og/custom-card.png"
    assert_response :success
    @og.key_resolver = ->(key) { key.start_with?("post-") ? SeoGeo::Page.from_hash(:post, { title: "Post" }) : nil }
    get "/og/post-7.png"
    assert_response :success
    get "/og/user-7.png"
    assert_equal "app og user-7", response.body
    assert_equal [["custom-card", nil, {}], ["post-7", "Post", {}]], @calls
  end

  # without a backend or template the engine draws no OG route, even for a page key.
  def test_app_og_route_wins_while_og_image_is_not_configured
    @og.backend = nil
    get "/og/home.png"
    assert_equal "app og home", response.body
    @og.enabled = true
    @og.backend = fake_backend
    get "/og/home.png"
    assert_equal "image/png", response.media_type
  ensure
    @og.enabled = nil
  end

  def test_param_values_outside_their_constraint_are_400_without_rendering
    @og.backend = fake_backend
    @og.permitted_params = %w[theme]
    @og.param_constraints = { "theme" => /[a-z]{1,10}/ }
    get "/og/home.png", params: { theme: "Dark1" }
    assert_response :bad_request
    get "/og/home.png", params: { theme: "a" * 11 }
    assert_response :bad_request
    @og.max_param_length = 3
    get "/og/home.png", params: { theme: "dark" }
    assert_response :bad_request
    assert_empty @calls
  end

  def test_saturated_renders_get_503_or_fallback_without_queueing
    @og.backend = fake_backend
    @og.max_concurrent = 1
    SeoGeo::OgImage.stub(:active_renders, 1) do
      get "/og/home.png"
      assert_response :service_unavailable
      assert_equal "5", response.headers["Retry-After"]
      @og.fallback_url = "https://cdn.example.com/og-default.png"
      get "/og/home.png"
      assert_redirected_to "https://cdn.example.com/og-default.png"
      assert_equal "no-store", response.headers["Cache-Control"]
    end
    assert_empty @calls
    get "/og/home.png"
    assert_response :success
  end

  def test_cached_until_template_version_changes
    @og.backend = fake_backend
    2.times { get "/og/home.png" }
    assert_equal 1, @calls.size
    @og.template_version = "2"
    get "/og/home.png"
    assert_equal 2, @calls.size
  end

  def test_backend_error_redirects_to_fallback_and_is_not_cached
    @og.backend = ->(*) { raise "boom" }
    @og.fallback_url = "https://cdn.example.com/og-default.png"
    get "/og/home.png"
    assert_redirected_to "https://cdn.example.com/og-default.png"
    assert_equal "max-age=300, public", response.headers["Cache-Control"]

    @og.backend = fake_backend
    get "/og/home.png"
    assert_response :success
  end

  # a raising key_resolver failed in routing, outside the controller's fallback handling.
  def test_raising_key_resolver_gets_the_configured_fallback
    @og.backend = fake_backend
    @og.key_resolver = ->(_key) { raise "database down" }
    @og.fallback_url = "https://cdn.example.com/og-default.png"
    get "/og/post-9.png"
    assert_redirected_to "https://cdn.example.com/og-default.png"
    @og.fallback_url = nil
    get "/og/post-9.png"
    assert_response :not_found
    assert_empty @calls
  end

  def test_non_png_bytes_fall_back
    @og.backend = ->(*) { "<html>" }
    @og.fallback_url = "https://cdn.example.com/og-default.png"
    get "/og/home.png"
    assert_response :redirect
  end

  def test_error_without_fallback_is_404
    @og.backend = ->(*) { raise "boom" }
    @og.fallback_url = nil
    get "/og/home.png"
    assert_response :not_found
  end
end
