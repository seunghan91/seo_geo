# frozen_string_literal: true

require "set"
require "nokogiri"

module SeoGeo
  # Robots directives of one response, from every +<meta name="robots">+, every crawler-specific meta
  # (+<meta name="googlebot">+) and every +X-Robots-Tag+ header, kept apart by scope:
  # +global+ applies to every crawler, +scoped["googlebot"]+ only to that one. A crawler obeys the union of
  # +global+ and its own scope, so a scoped directive never stands in for a global one.
  #
  # Shared by the Markdown response (copies the HTML's directives into +X-Robots-Tag+) and the audit
  # (is a sitemap page noindex?).
  #
  # @example
  #   directives = SeoGeo::RobotsDirectives.from_html(html).merge(SeoGeo::RobotsDirectives.parse_header(value))
  #   directives.noindex?              # global noindex
  #   directives.noindex?("googlebot") # global or googlebot-scoped
  #   directives.to_header             # "noindex, googlebot: nofollow"
  class RobotsDirectives
    # Directives that carry a value after a colon; any other +name: rest+ token in a header names a crawler.
    VALUE_DIRECTIVES = %w[max-snippet max-image-preview max-video-preview unavailable_after].freeze
    # Meta names that address one crawler (besides the crawler table's tokens).
    CRAWLER_META_NAMES = %w[googlebot googlebot-news googlebot-image bingbot msnbot slurp yandex yeti naverbot
                            daumoa baiduspider duckduckbot applebot].freeze
    PERMISSIVE = %w[index follow all].freeze

    # @return [Set<String>]
    attr_reader :global
    # @return [Hash{String => Set<String>}] crawler token (lower case) => directives
    attr_reader :scoped

    # @param html [String, Nokogiri::HTML::Document]
    # @return [RobotsDirectives]
    def self.from_html(html)
      doc = html.is_a?(Nokogiri::XML::Node) ? html : Nokogiri::HTML(html.to_s)
      new.tap do |directives|
        doc.css("meta[name]").each do |node|
          name = node["name"].to_s.strip.downcase
          if name == "robots"
            directives.add(nil, node["content"])
          elsif crawler_name?(name)
            directives.add(name, node["content"])
          end
        end
      end
    end

    # @param value [String, Array<String>, nil] one or several +X-Robots-Tag+ values (Rack joins repeated
    #   headers with "\n"). Within one value, +bot: ...+ scopes the following directives to +bot+.
    # @return [RobotsDirectives]
    def self.parse_header(value)
      new.tap do |directives|
        Array(value).flat_map { |item| item.to_s.split("\n") }.each do |line|
          scope = nil
          tokens(line).each do |token|

            name, rest = token.split(":", 2).map(&:strip)
            if rest && !VALUE_DIRECTIVES.include?(name.downcase)
              scope = name.downcase
              token = rest
            end
            directives.add(scope, token)
          end
        end
      end
    end

    # A date-valued +unavailable_after+ may contain a comma (RFC 850/1123: +Wed, 03 Dec 2025 13:09:53 GMT+). The
    # piece after +unavailable_after: <weekday>+ belongs to that directive, not to a new one.
    DATE_HEAD = /(?:\A|:)\s*unavailable_after\s*:\s*[A-Za-z]+\s*\z/i

    # Splits a comma-separated directive list, keeping date commas inside +unavailable_after+.
    # @param content [String, nil]
    # @return [Array<String>] stripped, non-empty tokens
    def self.tokens(content)
      content.to_s.split(",").each_with_object([]) do |piece, list|
        if list.last&.match?(DATE_HEAD)
          list[-1] = "#{list.last},#{piece.rstrip}"
        else
          list << piece.strip
        end
      end.reject(&:empty?)
    end

    # @param name [String] lower-case meta name
    # @return [Boolean]
    def self.crawler_name?(name)
      CRAWLER_META_NAMES.include?(name) || Crawlers::ALL.any? { |crawler| crawler.user_agent.casecmp?(name) }
    end

    def initialize
      @global = Set.new
      @scoped = {}
    end

    # @param scope [String, nil] crawler token; nil => every crawler
    # @param content [String, nil] comma-separated directives
    # @return [self]
    def add(scope, content)
      target = scope ? (@scoped[scope.downcase] ||= Set.new) : @global
      self.class.tokens(content).each do |raw|
        directive = canonical(raw)
        next if directive.empty?

        directive == "none" ? target.merge(%w[noindex nofollow]) : target << directive
      end
      @scoped.delete(scope.downcase) if scope && target.empty?
      self
    end

    # @param other [RobotsDirectives]
    # @return [RobotsDirectives] a new object with both sets of directives; nothing is dropped
    def merge(other)
      self.class.new.tap do |result|
        result.global.merge(global).merge(other.global)
        [scoped, other.scoped].each do |source|
          source.each { |bot, set| (result.scoped[bot] ||= Set.new).merge(set) }
        end
      end
    end

    # @return [RobotsDirectives] copy without +index+/+follow+/+all+ (they restrict nothing)
    def restrictive
      self.class.new.tap do |result|
        result.global.merge(global - PERMISSIVE)
        scoped.each do |bot, set|
          rest = set - PERMISSIVE
          result.scoped[bot] = rest unless rest.empty?
        end
      end
    end

    # @param bot [String, nil] crawler token; nil => global directives only
    # @return [Boolean]
    def noindex?(bot = nil)
      global.include?("noindex") || (!bot.nil? && scoped.fetch(bot.downcase, Set.new).include?("noindex"))
    end

    # @return [Boolean] true when any crawler is told noindex (globally or in its own scope)
    def noindex_for_any?
      global.include?("noindex") || scoped.each_value.any? { |set| set.include?("noindex") }
    end

    # @return [Boolean]
    def empty?
      global.empty? && scoped.empty?
    end

    # @return [String] one +X-Robots-Tag+ value: global directives first (a scope runs to the end of the value,
    #   so unscoped ones must precede every +bot:+), then each crawler's
    def to_header
      parts = global.to_a
      scoped.each { |bot, set| parts << "#{bot}: #{set.to_a.join(", ")}" unless set.empty? }
      parts.join(", ")
    end

    def ==(other)
      other.is_a?(RobotsDirectives) && global == other.global && scoped == other.scoped
    end

    private

    # Lower-cases the directive name; a value after +:+ keeps its case (+unavailable_after: 25 Jun 2026+).
    def canonical(raw)
      name, value = raw.strip.split(":", 2)
      value.nil? ? name.to_s.downcase : "#{name.downcase}:#{value}"
    end
  end
end
