# frozen_string_literal: true

require "seo_geo"
require_relative "testing/environment"

module SeoGeo
  # RSpec matchers. Plain matcher objects — seo_geo does not depend on rspec; when RSpec is
  # loaded, requiring this file includes the matchers into request specs.
  #
  # Each matcher accepts a response (anything with +#body+) or a String body.
  #
  # @example spec/requests/seo_spec.rb
  #   require "seo_geo/rspec"
  #
  #   it "folds the alias host" do
  #     host! "example.com"
  #     get "/pricing"
  #     expect(response).to have_seo_geo_canonical("https://www.example.com/pricing")
  #     expect(response).to have_seo_geo_single_title
  #   end
  #
  #   it "keeps the FAQ honest" do
  #     get "/"
  #     expect(response).to have_seo_geo_faq_matching_visible_text
  #   end
  #
  #   it "serves a valid sitemap" do
  #     get "/sitemap.xml"
  #     expect(response).to be_seo_geo_valid_sitemap(origin: "https://www.example.com")
  #   end
  #
  #   it "serves production robots" do
  #     with_seo_geo_environment("production") { get "/robots.txt" }
  #   end
  #
  #   it "keeps bots out of /admin" do
  #     get "/robots.txt"
  #     expect(response).not_to seo_geo_robots_allow("GPTBot", "/admin")
  #   end
  module RSpec
    # Base for the matchers below.
    class Matcher
      attr_reader :problems

      def initialize
        @problems = []
      end

      # @param actual [#body, String]
      # @return [Boolean]
      def matches?(actual)
        @problems = check(actual.respond_to?(:body) ? actual.body.to_s : actual.to_s)
        @problems.empty?
      end

      def does_not_match?(actual)
        !matches?(actual)
      end

      def failure_message
        "expected #{description}, but: #{problems.join("; ")}"
      end

      def failure_message_when_negated
        "expected not #{description}"
      end
    end

    # +<link rel="canonical">+ equals the expected URL.
    class CanonicalMatcher < Matcher
      def initialize(expected)
        super()
        @expected = expected
      end

      def description
        "canonical #{@expected}"
      end

      private

      def check(body)
        actual = Audit::HtmlDocument.new(body).canonical
        actual == @expected ? [] : ["canonical was #{actual.inspect}"]
      end
    end

    # Exactly one +<title>+.
    class SingleTitleMatcher < Matcher
      def description
        "exactly one <title>"
      end

      private

      def check(body)
        Audit::Checks.title_count(Audit::HtmlDocument.new(body))
      end
    end

    # FAQPage JSON-LD exists and every question/answer is in the visible text.
    class FaqMatcher < Matcher
      def description
        "FAQPage JSON-LD matching the visible FAQ"
      end

      private

      def check(body)
        doc = Audit::HtmlDocument.new(body)
        return ["no FAQPage JSON-LD"] if doc.faq_items.empty?

        Audit::Checks.faq_visible(doc)
      end
    end

    # Well-formed sitemap (urlset or sitemapindex) whose URLs are on +origin+.
    class SitemapMatcher < Matcher
      def initialize(origin)
        super()
        @origin = origin
      end

      def description
        "a valid sitemap#{" on #{@origin}" if @origin}"
      end

      private

      def check(body)
        Audit::Checks.sitemap(body, origin: @origin && "#{@origin.chomp("/")}/").first
      end
    end

    # robots.txt lets +user_agent+ fetch +path+.
    class RobotsMatcher < Matcher
      def initialize(user_agent, path)
        super()
        @user_agent = user_agent
        @path = path
      end

      def description
        "robots.txt to allow #{@user_agent} to fetch #{@path}"
      end

      def failure_message_when_negated
        "expected robots.txt to disallow #{@user_agent} #{@path}, but it is allowed"
      end

      private

      def check(body)
        evaluator = Robots::Evaluator.new(body)
        return [] if evaluator.allowed?(@user_agent, @path)

        rule = evaluator.matching_rule(@user_agent, @path)
        ["#{rule.first.to_s.capitalize}: #{rule.last} applies (group #{evaluator.group_token(@user_agent)})"]
      end
    end

    # Matcher methods; included into request specs automatically when RSpec is loaded.
    module Matchers
      include SeoGeo::Testing::EnvironmentHelper
      # @param url [String]
      def have_seo_geo_canonical(url) # rubocop:disable Naming/PredicateName
        CanonicalMatcher.new(url)
      end

      def have_seo_geo_single_title # rubocop:disable Naming/PredicateName
        SingleTitleMatcher.new
      end

      def have_seo_geo_faq_matching_visible_text # rubocop:disable Naming/PredicateName
        FaqMatcher.new
      end

      # @param origin [String, nil]
      def be_seo_geo_valid_sitemap(origin: nil)
        SitemapMatcher.new(origin)
      end

      # @param user_agent [String]
      # @param path [String]
      def seo_geo_robots_allow(user_agent, path)
        RobotsMatcher.new(user_agent, path)
      end
    end
  end
end

if defined?(::RSpec) && ::RSpec.respond_to?(:configure)
  ::RSpec.configure do |config|
    config.include SeoGeo::RSpec::Matchers, type: :request
    config.include SeoGeo::RSpec::Matchers, type: :controller
  end
end
