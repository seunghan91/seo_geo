# frozen_string_literal: true

require "test_helper"

class BootTest < ActionDispatch::IntegrationTest
  def test_rails_config_is_the_seo_geo_singleton
    assert_same SeoGeo.config, Rails.application.config.seo_geo
    assert_equal "https://www.example.com", SeoGeo.config.canonical_origin
    assert_empty SeoGeo.config.errors
  end

  def test_engine_is_mounted_at_root
    mounted = Rails.application.routes.routes.find { |route| route.app.app == SeoGeo::Engine }
    refute_nil mounted
    assert_equal "/", mounted.path.spec.to_s
  end

  def test_pages_load_from_the_app_yaml
    assert_includes SeoGeo.pages.paths, Rails.root.join("config/seo_geo/pages").to_s
    assert_equal "Dummy home", SeoGeo.page(:home, locale: :en).title
    assert_equal "더미 홈", SeoGeo.page(:home, locale: :ko).title
  end

  def test_home_renders
    get "/"
    assert_response :success
    if inertia_dummy?
      assert_match(%r{<div id="app" data-page="[^"]*Dummy home[^"]*"></div>}, response.body)
      assert_match(/<main data-seo-fallback>\s*<h1>Welcome to Dummy<\/h1>/, response.body, "h1 only in the crawler fallback")
    else
      assert_includes response.body, "<h1>Welcome to Dummy</h1>"
      assert_includes response.body, "<title>Dummy home | Dummy</title>"
    end
  end
end
