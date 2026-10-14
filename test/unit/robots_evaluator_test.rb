# frozen_string_literal: true

require "test_helper"

class RobotsEvaluatorTest < Minitest::Test
  BODY = <<~ROBOTS
    User-agent: *
    User-agent: GPTBot
    Allow: /.well-known/
    Disallow: /admin
    Disallow: /*.pdf$

    User-agent: CCBot
    Allow: /.well-known/
    Disallow: /

    User-agent: Claude-SearchBot
    Disallow:
  ROBOTS

  def rules
    SeoGeo::Robots::Evaluator.new(BODY)
  end

  def test_longest_match_and_allow_wins_ties
    refute rules.allowed?("GPTBot", "/admin/users")
    assert rules.allowed?("GPTBot", "/")
    refute rules.allowed?("CCBot", "/about")
    assert rules.allowed?("CCBot", "/.well-known/assetlinks.json")
    tie = SeoGeo::Robots::Evaluator.new("User-agent: *\nDisallow: /a\nAllow: /a\n")
    assert tie.allowed?("x", "/a")
  end

  def test_group_choice_by_token_and_full_user_agent
    assert_equal "ccbot", rules.group_token("CCBot/2.0 (https://commoncrawl.org/faq/)")
    refute rules.allowed?("CCBot/2.0 (https://commoncrawl.org/faq/)", "/about")
    assert_equal "*", rules.group_token("Mozilla/5.0 Safari")
    refute rules.allowed?("SomeBot", "/admin")
    assert rules.allowed?("Claude-SearchBot", "/admin"), "an empty Disallow allows everything"
  end

  def test_wildcards
    refute rules.allowed?("*", "/files/a.pdf")
    assert rules.allowed?("*", "/files/a.pdf?x=1")
    assert_equal [:disallow, "/admin"], rules.matching_rule("GPTBot", "/admin")
    assert_nil rules.matching_rule("GPTBot", "/ok")
  end

  # Agrees with the robots.txt seo_geo itself emits.
  def test_reads_generated_robots
    config = configured(environment: "production")
    config.host "www.example.com", disallow: ["/admin"]
    config.crawlers.training = :deny
    evaluator = SeoGeo::Robots::Evaluator.new(SeoGeo::Robots.new(config, "www.example.com").to_s)
    refute evaluator.allowed?("GPTBot", "/")
    refute evaluator.allowed?("Googlebot", "/admin")
    assert evaluator.allowed?("Googlebot", "/")
    assert evaluator.allowed?("OAI-SearchBot", "/pricing")
  end

  def test_percent_encoding_is_normalized
    refute rules.allowed?("GPTBot", "/%61dmin")
    korean = SeoGeo::Robots::Evaluator.new("User-agent: *\nDisallow: /가이드\n")
    refute korean.allowed?("x", "/%ea%b0%80%ec%9d%b4%eb%93%9c/a")
    assert_equal [:disallow, "/가이드"], korean.matching_rule("x", "/%EA%B0%80%EC%9D%B4%EB%93%9C")
  end

  def test_escaped_special_characters_are_literals
    rules = SeoGeo::Robots::Evaluator.new("User-agent: *\nDisallow: /path/foo-%24\nDisallow: /star%2A\n")
    refute rules.allowed?("x", "/path/foo-$")
    refute rules.allowed?("x", "/star*")
    assert rules.allowed?("x", "/starry")
  end
end
