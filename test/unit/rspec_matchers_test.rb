# frozen_string_literal: true

require "test_helper"
require "seo_geo/rspec"

# The RSpec matchers are plain objects; exercised here without loading rspec.
class RSpecMatchersTest < Minitest::Test
  include SeoGeo::RSpec::Matchers

  Response = Struct.new(:body)

  PAGE = <<~HTML
    <html lang="en"><head><title>Home</title><link rel="canonical" href="https://www.example.com/">
    <script type="application/ld+json">{"@type":"FAQPage","mainEntity":[{"@type":"Question","name":"Free?","acceptedAnswer":{"@type":"Answer","text":"Yes."}}]}</script>
    </head><body><h3>Free?</h3><p>Yes.</p></body></html>
  HTML

  def test_canonical_title_and_faq
    assert have_seo_geo_canonical("https://www.example.com/").matches?(Response.new(PAGE))
    matcher = have_seo_geo_canonical("https://www.example.com/x")
    refute matcher.matches?(PAGE)
    assert_includes matcher.failure_message, 'canonical was "https://www.example.com/"'
    assert have_seo_geo_single_title.matches?(PAGE)
    refute have_seo_geo_single_title.matches?(PAGE.sub("</head>", "<title>Two</title></head>"))
    assert have_seo_geo_faq_matching_visible_text.matches?(PAGE)
    faq = have_seo_geo_faq_matching_visible_text
    refute faq.matches?(PAGE.sub("<p>Yes.</p>", ""))
    assert_includes faq.failure_message, "FAQ answer not in visible text"
    refute have_seo_geo_faq_matching_visible_text.matches?("<html><body>no faq</body></html>")
  end

  def test_sitemap_and_robots
    xml = %(<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://www.example.com/</loc></url></urlset>)
    assert be_seo_geo_valid_sitemap(origin: "https://www.example.com").matches?(xml)
    refute be_seo_geo_valid_sitemap(origin: "https://start.example.com").matches?(xml)

    robots = "User-agent: *\nDisallow: /admin\n"
    assert seo_geo_robots_allow("GPTBot", "/").matches?(robots)
    matcher = seo_geo_robots_allow("GPTBot", "/admin/x")
    assert matcher.does_not_match?(robots)
    refute matcher.matches?(robots)
    assert_includes matcher.failure_message, "Disallow: /admin applies (group *)"
  end
end
