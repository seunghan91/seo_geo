# frozen_string_literal: true

require "json"
require "yaml"
require "nokogiri"

module SeoGeo
  module Markdown
    # Turns a rendered HTML page into a Markdown document for agents:
    #
    #   ---
    #   title: ...          # <title>, else page copy
    #   description: ...    # meta description
    #   canonical: ...      # link rel=canonical, else config.canonical_url(request URL)
    #   image: ...          # og:image
    #   locale: ...         # <html lang>
    #   ---
    #
    #   <main content converted to Markdown>
    #
    #   ```json
    #   <each JSON-LD block>
    #   ```
    #
    # When the HTML has no main content (an Inertia/SPA mount point) and a {SeoGeo::Page} is given, the
    # body comes from {SeoGeo::Page#to_markdown}, so agents see the same copy as the crawler fallback.
    class Document
      # Removed before conversion wherever they appear.
      NOISE = %w[script style noscript template iframe svg canvas nav form button dialog].freeze
      # Removed as well when no main element exists and the whole body is converted.
      CHROME = %w[header footer aside].freeze

      # @return [String]
      attr_reader :html

      # @param html [String] the rendered HTML response body
      # @param config [Configuration]
      # @param url [String, nil] request URL, used for the canonical fallback
      # @param page [Page, nil] page copy for client-rendered pages
      # @param selector [String, nil] main-content selector; nil uses +config.markdown.selector+
      def initialize(html, config: SeoGeo.config, url: nil, page: nil, selector: nil)
        @html = html.to_s
        @config = config
        @url = url
        @page = page
        @selector = selector || config.markdown.selector
      end

      # @return [String] the full Markdown document
      def to_s
        body = body_markdown
        parts = [frontmatter, body.strip]
        json_ld.each { |block| parts << "```json\n#{block}\n```" }
        "#{parts.reject(&:empty?).join("\n\n")}\n"
      end

      # @return [Hash{String => String}] frontmatter fields that have a value
      def metadata
        {
          "title" => text_at("head > title") || @page&.title,
          "description" => attribute_at('meta[name="description"]', "content") || @page&.description,
          "canonical" => attribute_at('link[rel="canonical"]', "href") || canonical_fallback,
          "image" => attribute_at('meta[property="og:image"]', "content"),
          "locale" => attribute_at("html", "lang") || @page&.locale&.to_s
        }.reject { |_name, value| value.nil? || value.to_s.strip.empty? }
      end

      # @return [RobotsDirectives] every robots and crawler-specific meta of the HTML
      def robots
        @robots ||= RobotsDirectives.from_html(doc)
      end

      # Global directives (every +<meta name="robots">+), lower-cased, +none+ expanded to +noindex, nofollow+.
      # @return [Array<String>]
      def robots_directives
        robots.global.to_a
      end

      # @return [Boolean] true when the HTML asks every robot not to index the page
      def noindex?
        robots.noindex?
      end

      # @return [Array<String>] pretty-printed JSON-LD blocks
      def json_ld
        doc.css('script[type="application/ld+json"]').filter_map do |node|
          raw = node.text.strip
          next if raw.empty?

          begin
            JSON.pretty_generate(JSON.parse(raw))
          rescue JSON::ParserError
            raw
          end
        end
      end

      private

      def doc
        @doc ||= if defined?(Nokogiri::HTML5) then Nokogiri::HTML5(@html)
                 else Nokogiri::HTML(@html)
                 end
      end

      def frontmatter
        data = metadata
        return "" if data.empty?

        "#{YAML.dump(data).sub(/\A---\s*\n/, "---\n")}---"
      end

      def body_markdown
        from_html = convert(main_html)
        return from_html unless from_html.strip.empty? && @page

        @page.to_markdown
      end

      # HTML of the main content with noise removed. Works on a copy so metadata/JSON-LD stay readable.
      def main_html
        copy = doc.dup
        main = copy.at_css(@selector)
        root = main || copy.at_css("body")
        return "" if root.nil?

        removable = main ? NOISE : NOISE + CHROME
        root.css(removable.join(",")).each(&:remove)
        root.inner_html
      end

      def convert(fragment)
        return "" if fragment.strip.empty?

        converter = @config.markdown.converter
        markdown = if converter.respond_to?(:call)
                     converter.call(fragment)
                   else
                     require "reverse_markdown"
                     ReverseMarkdown.convert(fragment, unknown_tags: :bypass, github_flavored: true)
                   end
        markdown.to_s.gsub(/\n{3,}/, "\n\n")
      end

      def text_at(selector)
        node = doc.at_css(selector)
        value = node&.text&.strip
        value unless value.nil? || value.empty?
      end

      def attribute_at(selector, name)
        value = doc.at_css(selector)&.[](name)&.strip
        value unless value.nil? || value.empty?
      end

      def canonical_fallback
        return nil if @url.nil? || @config.canonical_origin.nil?

        @config.canonical_url(@url)
      end
    end
  end
end
