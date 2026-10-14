# frozen_string_literal: true

require "json"
require "nokogiri"

module SeoGeo
  module Audit
    # Read-only view of one HTML response: the values crawlers take from it.
    class HtmlDocument
      NON_VISIBLE = "script, style, template, head"

      # @param html [String]
      def initialize(html)
        @doc = Nokogiri::HTML(html.to_s)
      end

      # @return [Array<String>] text of every +<title>+ in the head (SVG titles ignored)
      def titles
        @doc.xpath("//head/title").map { |node| squish(node.text) }
      end

      # @return [String, nil] the first title
      def title
        titles.first
      end

      # @return [String, nil]
      def description
        meta_content("description")
      end

      # @return [String, nil] href of +<link rel="canonical">+
      def canonical
        @doc.css("link[rel~=canonical]").first&.[]("href")
      end

      # @return [String, nil] first robots meta content (lower case); {#noindex?} reads all of them
      def robots
        meta_content("robots")&.downcase
      end

      # @return [RobotsDirectives] every robots and crawler-specific meta ({RobotsDirectives.from_html}, the
      #   parser the Markdown response uses)
      def robots_directives
        @robots_directives ||= RobotsDirectives.from_html(@doc)
      end

      # @param header [String, Array<String>, nil] the response's +X-Robots-Tag+
      # @return [Boolean] true when any meta or the header tells any crawler noindex (+none+ included)
      def noindex?(header = nil)
        robots_directives.merge(RobotsDirectives.parse_header(header)).noindex_for_any?
      end

      # @return [String, nil] +<html lang>+
      def html_lang
        value = @doc.at_xpath("/html")&.[]("lang")
        value.nil? || value.strip.empty? ? nil : value
      end

      # @return [String, nil] href of +<link rel="alternate" type="text/markdown">+
      def markdown_alternate
        @doc.css("link[rel~=alternate]").find { |node| node["type"].to_s.casecmp?("text/markdown") }&.[]("href")
      end

      # @param name [String] meta name, e.g. "google-site-verification"
      # @return [String, nil]
      def meta_content(name)
        node = @doc.css("meta[name]").find { |item| item["name"].casecmp?(name) }
        node && node["content"]
      end

      # @return [Array<String>] raw bodies of +<script type="application/ld+json">+
      def json_ld_sources
        @doc.css("script").select { |node| node["type"].to_s.strip.casecmp?("application/ld+json") }.map(&:text)
      end

      # @return [Array(Array<Hash>, Array<String>)] parsed nodes (@graph flattened) and parse error messages
      def json_ld
        nodes = []
        errors = []
        json_ld_sources.each_with_index do |source, index|
          nodes.concat(flatten(JSON.parse(source)))
        rescue JSON::ParserError => e
          errors << "JSON-LD block #{index + 1} does not parse: #{e.message.lines.first.to_s.strip[0, 120]}"
        end
        [nodes, errors]
      end

      # @return [Array<Hash{Symbol => String}>] +{question:, answer:}+ from every FAQPage node
      def faq_items
        json_ld.first.select { |node| types(node).include?("FAQPage") }.flat_map do |node|
          Array(node["mainEntity"]).filter_map do |question|
            next unless question.is_a?(Hash)

            answer = question["acceptedAnswer"]
            answer = answer.first if answer.is_a?(Array)
            { question: squish(question["name"].to_s), answer: squish(answer.is_a?(Hash) ? answer["text"].to_s : "") }
          end
        end
      end

      # @return [String] text a crawler that does not run JavaScript reads (scripts, styles, head removed)
      def visible_text
        @visible_text ||= begin
          copy = @doc.dup
          copy.css(NON_VISIBLE).each(&:remove)
          squish(copy.text)
        end
      end

      # @param node [Hash]
      # @return [Array<String>]
      def types(node)
        Array(node["@type"]).map(&:to_s)
      end

      private

      def flatten(value)
        case value
        when Array then value.flat_map { |item| flatten(item) }
        when Hash then value.key?("@graph") ? flatten(value["@graph"]) : [value]
        else []
        end
      end

      def squish(text)
        text.to_s.gsub(/[[:space:]]+/, " ").strip
      end
    end
  end
end
