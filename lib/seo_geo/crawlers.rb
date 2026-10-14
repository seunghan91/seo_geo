# frozen_string_literal: true

module SeoGeo
  # Canonical user-agent table, grouped by what the operator uses the fetch for.
  #
  # Purposes:
  # - +:training+ — model training corpora. Blocking these never affects search inclusion.
  # - +:search+   — search / answer-engine indexes (classic and AI search).
  # - +:user+     — fetches triggered by a person asking an assistant about a URL.
  #   Several operators state robots.txt may not apply to these; see {Crawler#honors_robots}.
  #
  # Sources (checked 2026-10-14): developers.openai.com/api/docs/bots,
  # support.claude.com/en/articles/8896518, docs.perplexity.ai/guides/bots,
  # developers.google.com/search/docs/crawling-indexing/google-common-crawlers,
  # support.apple.com/en-us/119829, developers.facebook.com/docs/sharing/webmasters/web-crawlers,
  # commoncrawl.org/ccbot, searchadvisor.naver.com/guide/seo-basic-robots.
  module Crawlers
    PURPOSES = %i[training search user].freeze

    # One robots.txt user-agent token.
    #
    # @!attribute user_agent [String] token as written in a robots.txt +User-agent:+ line
    # @!attribute owner [String] operator name
    # @!attribute purpose [Symbol] one of {PURPOSES}
    # @!attribute honors_robots [Boolean, Symbol] true, or +:unreliable+ / +:may_ignore+ when the
    #   operator says (or reports show) robots.txt may not be applied
    # @!attribute token_only [Boolean] true for control tokens that never fetch on their own
    #   (Google-Extended, Applebot-Extended); they only appear in robots.txt
    Crawler = Data.define(:user_agent, :owner, :purpose, :honors_robots, :token_only)

    def self.entry(user_agent, owner, purpose, honors_robots: true, token_only: false)
      Crawler.new(user_agent: user_agent, owner: owner, purpose: purpose,
                  honors_robots: honors_robots, token_only: token_only).freeze
    end
    private_class_method :entry

    # @return [Array<Crawler>] the full table, frozen
    ALL = [
      entry("GPTBot", "OpenAI", :training),
      entry("ClaudeBot", "Anthropic", :training),
      entry("Google-Extended", "Google", :training, token_only: true),
      entry("Applebot-Extended", "Apple", :training, token_only: true),
      entry("CCBot", "Common Crawl", :training),
      entry("Meta-ExternalAgent", "Meta", :training),
      entry("Bytespider", "ByteDance", :training, honors_robots: :unreliable),

      entry("Googlebot", "Google", :search),
      entry("Bingbot", "Microsoft", :search),
      entry("Yeti", "Naver", :search),
      entry("OAI-SearchBot", "OpenAI", :search),
      entry("Claude-SearchBot", "Anthropic", :search),
      entry("PerplexityBot", "Perplexity", :search),

      entry("ChatGPT-User", "OpenAI", :user, honors_robots: :may_ignore),
      entry("Claude-User", "Anthropic", :user),
      entry("Perplexity-User", "Perplexity", :user, honors_robots: :may_ignore),
      entry("Meta-ExternalFetcher", "Meta", :user, honors_robots: :may_ignore)
    ].freeze

    # @return [Hash{Symbol => Array<String>}] default user-agent tokens per purpose, frozen
    DEFAULT_USER_AGENTS = PURPOSES.to_h do |purpose|
      [purpose, ALL.select { |crawler| crawler.purpose == purpose }.map(&:user_agent).freeze]
    end.freeze

    # @param user_agent [String] robots.txt token (case-insensitive) or a full User-Agent header
    # @return [Crawler, nil] the table entry whose token appears in +user_agent+
    def self.find(user_agent)
      return nil if user_agent.nil? || user_agent.empty?

      needle = user_agent.downcase
      exact = ALL.find { |crawler| crawler.user_agent.downcase == needle }
      return exact if exact

      # Longest token first so "Claude-SearchBot" is not matched by a shorter token.
      ALL.sort_by { |crawler| -crawler.user_agent.length }
         .find { |crawler| needle.include?(crawler.user_agent.downcase) }
    end
  end
end
