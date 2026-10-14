# frozen_string_literal: true

require "seo_geo"
require "uri"
require_relative "testing/environment"

module SeoGeo
  # Minitest assertions for an app's integration tests. They use the same checks as
  # +rake seo_geo:audit+ ({Audit::Checks}), so a passing test and a clean audit agree.
  #
  # @example test/integration/seo_test.rb
  #   require "seo_geo/testing"
  #
  #   class SeoTest < ActionDispatch::IntegrationTest
  #     include SeoGeo::Testing::Assertions
  #
  #     test("alias host folds")  { assert_seo_geo_canonical "/pricing", host: "example.com" }
  #     test("faq is visible")    { assert_seo_geo_faq_matches_visible "/" }
  #     test("one title")         { assert_seo_geo_single_title "/" }
  #     test("sitemap")           { assert_seo_geo_sitemap host: "www.example.com" }
  #     test("no alias sitemap")  { assert_seo_geo_no_sitemap host: "example.com" }
  #     test("admin is closed")   { refute_seo_geo_robots_allows "GPTBot", "/admin", host: "www.example.com" }
  #     test("production robots") { with_seo_geo_environment("production") { assert_seo_geo_sitemap host: "www.example.com" } }
  #   end
  module Testing
    # Include into +ActionDispatch::IntegrationTest+ (needs +host!+, +get+ and +response+).
    # Each assertion takes a +path+ and requests it; pass +path = nil+ to check the last response.
    module Assertions
      include EnvironmentHelper
      # The page's +<link rel="canonical">+ equals +expected+ (default: {Configuration#canonical_url} of the
      # requested URL — on an alias host that is the canonical origin).
      # @param path [String, nil]
      # @param host [String, nil]
      # @param expected [String, nil]
      def assert_seo_geo_canonical(path, host: nil, expected: nil)
        seo_geo_get(path, host)
        expected ||= SeoGeo.config.canonical_url(request.url)
        actual = Audit::HtmlDocument.new(response.body).canonical
        assert_equal expected, actual, "canonical of #{request.url}"
      end

      # Exactly one +<title>+ in the head.
      # @param path [String, nil]
      # @param host [String, nil]
      def assert_seo_geo_single_title(path = nil, host: nil)
        seo_geo_get(path, host)
        problems = Audit::Checks.title_count(Audit::HtmlDocument.new(response.body))
        assert_empty problems, "#{request.url}: #{problems.join("; ")}"
      end

      # Every FAQPage question and answer in the JSON-LD also appears in the visible text (or the
      # crawler fallback body), and at least one FAQPage exists.
      # @param path [String, nil]
      # @param host [String, nil]
      def assert_seo_geo_faq_matches_visible(path = nil, host: nil)
        seo_geo_get(path, host)
        doc = Audit::HtmlDocument.new(response.body)
        refute_empty doc.faq_items, "#{request.url} has no FAQPage JSON-LD"
        problems = Audit::Checks.faq_visible(doc)
        assert_empty problems, "#{request.url}: #{problems.join("; ")}"
      end

      # /sitemap.xml on +host+ is 200, well-formed, in the sitemaps.org namespace, and lists only URLs
      # on the host's origin.
      # @param host [String]
      # @return [Array<String>] the +<loc>+ values
      def assert_seo_geo_sitemap(host:)
        seo_geo_get("/sitemap.xml", host)
        assert_equal 200, response.status, "/sitemap.xml on #{host}"
        problems, locs, = Audit::Checks.sitemap(response.body, origin: "#{SeoGeo.config.origin_for(host)}/")
        assert_empty problems, "/sitemap.xml on #{host}: #{problems.join("; ")}"
        locs
      end

      # /sitemap.xml on +host+ is a 404 (alias, undeclared or non-indexable host).
      # @param host [String]
      def assert_seo_geo_no_sitemap(host:)
        seo_geo_get("/sitemap.xml", host)
        assert_equal 404, response.status, "/sitemap.xml on #{host} should be 404"
      end

      # robots.txt on +host+ lets +user_agent+ fetch +path+ (RFC 9309 evaluation, {Robots::Evaluator}).
      # @param user_agent [String] token or full User-Agent header
      # @param path [String]
      # @param host [String, nil]
      def assert_seo_geo_robots_allows(user_agent, path, host: nil)
        assert seo_geo_robots(host).allowed?(user_agent, path), "robots.txt should allow #{user_agent} #{path}"
      end

      # robots.txt on +host+ disallows +path+ for +user_agent+.
      def refute_seo_geo_robots_allows(user_agent, path, host: nil)
        refute seo_geo_robots(host).allowed?(user_agent, path), "robots.txt should disallow #{user_agent} #{path}"
      end

      private

      def seo_geo_robots(host)
        seo_geo_get("/robots.txt", host)
        assert_equal 200, response.status, "/robots.txt"
        Robots::Evaluator.new(response.body)
      end

      def seo_geo_get(path, host)
        return if path.nil?

        host!(host) if host
        get path
      end
    end
  end
end
