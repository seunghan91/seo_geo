# frozen_string_literal: true

require "test_helper"

class CrawlersTest < Minitest::Test
  def test_table_is_frozen_and_complete
    assert SeoGeo::Crawlers::ALL.frozen?
    assert SeoGeo::Crawlers::ALL.all?(&:frozen?)
    assert SeoGeo::Crawlers::DEFAULT_USER_AGENTS.frozen?
    assert SeoGeo::Crawlers::DEFAULT_USER_AGENTS.values.all?(&:frozen?)
    assert_equal SeoGeo::Crawlers::PURPOSES, SeoGeo::Crawlers::DEFAULT_USER_AGENTS.keys
    assert_raises(FrozenError) { SeoGeo::Crawlers::DEFAULT_USER_AGENTS[:training] << "X" }
  end

  def test_tokens_are_unique_and_purposes_valid
    tokens = SeoGeo::Crawlers::ALL.map { |crawler| crawler.user_agent.downcase }
    assert_equal tokens.uniq, tokens
    assert SeoGeo::Crawlers::ALL.all? { |crawler| SeoGeo::Crawlers::PURPOSES.include?(crawler.purpose) }
  end

  def test_plan_groups
    groups = SeoGeo::Crawlers::DEFAULT_USER_AGENTS
    assert_equal %w[GPTBot ClaudeBot Google-Extended Applebot-Extended CCBot Meta-ExternalAgent Bytespider], groups[:training]
    assert_equal %w[Googlebot Bingbot Yeti OAI-SearchBot Claude-SearchBot PerplexityBot], groups[:search]
    assert_equal %w[ChatGPT-User Claude-User Perplexity-User Meta-ExternalFetcher], groups[:user]
  end

  def test_token_only_and_robots_compliance_flags
    assert_equal %w[Google-Extended Applebot-Extended], SeoGeo::Crawlers::ALL.select(&:token_only).map(&:user_agent)
    assert_equal :unreliable, SeoGeo::Crawlers.find("Bytespider").honors_robots
    assert_equal :may_ignore, SeoGeo::Crawlers.find("ChatGPT-User").honors_robots
  end

  def test_find_matches_tokens_and_full_headers
    assert_equal "Claude-SearchBot", SeoGeo::Crawlers.find("claude-searchbot").user_agent
    header = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
    assert_equal "ClaudeBot", SeoGeo::Crawlers.find(header).user_agent
    assert_equal "ChatGPT-User", SeoGeo::Crawlers.find("Mozilla/5.0 (compatible; ChatGPT-User/1.0)").user_agent
    assert_nil SeoGeo::Crawlers.find("Mozilla/5.0 Safari")
    assert_nil SeoGeo::Crawlers.find(nil)
  end

  def test_policy_resolution
    crawlers = SeoGeo::CrawlerOptions.new
    crawlers.training = :deny
    crawlers.add(:training, "NewTrainer")
    crawlers.override("Bytespider", :deny)
    crawlers.override("GPTBot", :allow)
    assert_equal :deny, crawlers.policy_for("claudebot")
    assert_equal :deny, crawlers.policy_for("NewTrainer")
    assert_equal :allow, crawlers.policy_for("GPTBot")
    assert_equal :allow, crawlers.policy_for("Googlebot")
    assert_nil crawlers.policy_for("UnknownBot")
    assert_includes crawlers.user_agents(:training), "NewTrainer"
    assert_raises(SeoGeo::ConfigurationError) { crawlers.add(:ads, "X") }
  end
end
