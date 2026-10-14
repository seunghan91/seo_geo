# frozen_string_literal: true

require "yaml"

module SeoGeo
  # The single source of page copy. The same object feeds the crawler fallback HTML, JSON-LD
  # (FAQPage must match visible text) and Inertia props, so the three can never drift.
  #
  # @!attribute key [Symbol]
  # @!attribute locale [Symbol, nil]
  # @!attribute title [String, nil]
  # @!attribute description [String, nil]
  # @!attribute heading [String, nil] visible H1
  # @!attribute intro [String, Array<String>, nil] lead paragraph, or several ({#intro_paragraphs})
  # @!attribute features [Array<Hash{Symbol => String}>] each +{title:, description:}+
  # @!attribute faq [Array<Hash{Symbol => String}>] each +{question:, answer:}+
  # @!attribute extra [Hash{Symbol => Object}] any other keys from the source, passed through to {#props}
  Page = Data.define(:key, :locale, :title, :description, :heading, :intro, :features, :faq, :extra) do
    # Builds a page from a loosely shaped hash (YAML, I18n or Ruby). Accepts +q+/+a+ as FAQ aliases
    # and +name+/+body+ as feature aliases.
    # @param key [Symbol, String]
    # @param data [Hash]
    # @param locale [Symbol, nil]
    # @return [Page]
    def self.from_hash(key, data, locale: nil)
      data = deep_copy(deep_symbolize(data || {}), freeze: true)
      known = %i[title description heading intro features faq]
      new(key: key.to_sym, locale: locale&.to_sym,
          title: data[:title], description: data[:description], heading: data[:heading], intro: data[:intro],
          features: Array(data[:features]).map { |item| normalize_feature(item) }.freeze,
          faq: Array(data[:faq]).map { |item| normalize_faq(item) }.freeze,
          extra: data.except(*known).freeze)
    end

    def self.deep_symbolize(value)
      case value
      when Hash then value.to_h { |name, inner| [name.to_sym, deep_symbolize(inner)] }
      when Array then value.map { |inner| deep_symbolize(inner) }
      else value
      end
    end

    # @api private
    # Copies Hash/Array/String nodes so a Page never shares mutable state with its source or its callers.
    # @param value [Object]
    # @param freeze [Boolean] freeze every copied node (registry storage) or leave them mutable ({#props})
    # @return [Object]
    def self.deep_copy(value, freeze:)
      copy = case value
             when Hash then value.to_h { |name, inner| [deep_copy(name, freeze: freeze), deep_copy(inner, freeze: freeze)] }
             when Array then value.map { |inner| deep_copy(inner, freeze: freeze) }
             when String then value.dup
             else return value
             end
      freeze ? copy.freeze : copy
    end

    def self.normalize_feature(item)
      return { title: item.to_s, description: nil }.freeze unless item.is_a?(Hash)

      { title: item[:title] || item[:name], description: item[:description] || item[:body] }.freeze
    end

    def self.normalize_faq(item)
      raise ConfigurationError, "faq items must be hashes with question/answer" unless item.is_a?(Hash)

      { question: item[:question] || item[:q], answer: item[:answer] || item[:a] }.freeze
    end
    private_class_method :deep_symbolize, :normalize_feature, :normalize_faq

    # @return [Array<String>] +intro+ as paragraphs (a String is one paragraph; blanks dropped)
    def intro_paragraphs
      Array(intro).map(&:to_s).reject { |line| line.strip.empty? }
    end

    # Shape (all keys always present, Symbol keys; +extra+ keys merged at the top level):
    #   { key: Symbol, locale: Symbol | nil, title: String | nil, description: String | nil, heading: String | nil,
    #     intro: String | Array<String> | nil (as written in the source),
    #     features: [{ title:, description: }], faq: [{ question:, answer: }], **extra }
    # Sources may write FAQ items as +q+/+a+ and features as +name+/+body+; props always carry the canonical
    # +question+/+answer+ and +title+/+description+.
    # @return [Hash{Symbol => Object}] detached, mutable deep copy for Inertia props / JSON APIs — changing it
    #   never reaches the registry or other requests
    def props
      Page.deep_copy({ key: key, locale: locale, title: title, description: description, heading: heading,
                       intro: intro, features: features, faq: faq }.merge(extra), freeze: false)
    end

    # Markdown rendering of the copy, used for Markdown negotiation on client-rendered pages.
    # @return [String]
    def to_markdown
      parts = []
      parts << "# #{heading || title}" if heading || title
      parts.concat(intro_paragraphs)
      unless features.empty?
        parts << "## Features"
        parts << features.map { |item| item[:description] ? "- **#{item[:title]}**: #{item[:description]}" : "- #{item[:title]}" }.join("\n")
      end
      unless faq.empty?
        parts << "## FAQ"
        faq.each { |item| parts << "### #{item[:question]}\n\n#{item[:answer]}" }
      end
      "#{parts.join("\n\n")}\n"
    end
  end

  # Loads {Page}s from three interchangeable sources, in this precedence: Ruby hash, I18n scope, YAML file.
  #
  # YAML files live at +config/seo_geo/pages/<key>.yml+. A file is either a flat attribute hash or a
  # hash keyed by locale (+ko:+, +en:+), in which case the requested locale (or site.default_locale) is used.
  #
  # @example
  #   SeoGeo.pages.register(:pricing, title: "Pricing", faq: [{ q: "Free?", a: "Yes" }])
  #   SeoGeo.pages.register_i18n(:login, scope: "views.login.seo", faq: :numbered) # q1_q / q1_a ...
  #   SeoGeo.page(:home).props
  class PageRegistry
    # @return [Array<String>] directories searched for +<key>.yml+
    attr_accessor :paths

    def initialize
      @paths = []
      @hashes = {}
      @i18n = {}
    end

    # @param key [Symbol, String]
    # @param data [Hash] page attributes, or a hash keyed by locale
    # @return [void]
    def register(key, data = nil, **attributes)
      @hashes[key.to_sym] = Page.deep_copy(data || attributes, freeze: true)
    end

    # @param key [Symbol, String]
    # @param scope [String] I18n scope holding title/description/heading/intro/features/faq
    # @param faq [Symbol] :list (an array under +faq+) or :numbered (+q1_q+/+q1_a+, +q2_q+/... keys)
    # @return [void]
    def register_i18n(key, scope:, faq: :list)
      raise ConfigurationError, "faq: must be :list or :numbered" unless %i[list numbered].include?(faq)

      @i18n[key.to_sym] = { scope: scope, faq: faq }
    end

    # @param key [Symbol, String]
    # @param locale [Symbol, String, nil] nil => I18n.locale when available, else site.default_locale
    # @raise [KeyError] when no source defines the page
    # @return [Page]
    def fetch(key, locale: nil)
      key = key.to_sym
      locale = (locale || current_locale).to_sym
      data = if @hashes.key?(key) then localized(@hashes[key], locale)
             elsif @i18n.key?(key) then from_i18n(@i18n[key], locale)
             else from_yaml(key, locale)
             end
      raise KeyError, "seo_geo page #{key.inspect} is not defined (looked in Ruby, I18n and #{paths.inspect})" if data.nil?

      Page.from_hash(key, data, locale: locale)
    end

    # @return [Array<Symbol>] every key known to any source
    def keys
      yaml_keys = paths.flat_map { |dir| Dir[File.join(dir, "*.yml")].map { |file| File.basename(file, ".yml").to_sym } }
      (@hashes.keys + @i18n.keys + yaml_keys).uniq
    end

    # @return [void]
    def clear
      @hashes.clear
      @i18n.clear
    end

    private

    # The request-locale rule ({Configuration#request_locale}) shared with +<html lang>+ and +og:locale+, so a
    # default fetch ({SeoGeo.page}, +seo_geo_page+, the crawler fallback) picks the same copy as the head.
    def current_locale
      SeoGeo.config.request_locale(defined?(I18n) && I18n.respond_to?(:locale) ? I18n.locale : nil)
    end

    def localized(data, locale)
      data = Page.send(:deep_symbolize, data)
      return data unless data.keys.any? { |name| name.to_s.match?(/\A[a-z]{2}(-[A-Za-z]{2,4})?\z/) && data[name].is_a?(Hash) }

      data[locale] || data[SeoGeo.config.site.default_locale.to_sym]
    end

    def from_yaml(key, locale)
      file = paths.map { |dir| File.join(dir, "#{key}.yml") }.find { |path| File.file?(path) }
      file && localized(YAML.safe_load_file(file, aliases: true) || {}, locale)
    end

    def from_i18n(source, locale)
      raw = I18n.t(source[:scope], locale: locale, default: nil)
      return nil unless raw.is_a?(Hash)
      return raw if source[:faq] == :list

      numbered = raw.keys.filter_map { |name| name.to_s[/\Aq(\d+)_q\z/, 1]&.to_i }.sort
      raw.reject { |name, _| name.to_s.match?(/\Aq\d+_[qa]\z/) }
         .merge(faq: numbered.map { |n| { question: raw[:"q#{n}_q"], answer: raw[:"q#{n}_a"] } })
    end
  end
end
