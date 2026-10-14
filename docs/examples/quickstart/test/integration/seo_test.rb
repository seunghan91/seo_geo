# test/integration/seo_test.rb
require "test_helper"
require "seo_geo/testing"

class SeoTest < ActionDispatch::IntegrationTest
  include SeoGeo::Testing::Assertions

  test "one title and a folded canonical" do
    assert_seo_geo_single_title "/"
    assert_seo_geo_canonical "/pricing", host: "example.com", expected: "https://www.example.com/pricing"
  end

  test "FAQ JSON-LD matches the visible text" do
    assert_seo_geo_faq_matches_visible "/"
  end

  test "production robots.txt and sitemap" do
    with_seo_geo_environment("production") do
      refute_seo_geo_robots_allows "GPTBot", "/", host: "www.example.com"
      assert_seo_geo_robots_allows "OAI-SearchBot", "/pricing", host: "www.example.com"
      refute_seo_geo_robots_allows "OAI-SearchBot", "/admin", host: "www.example.com"
      assert_seo_geo_sitemap host: "www.example.com"
      assert_seo_geo_no_sitemap host: "example.com"
    end
  end
end
