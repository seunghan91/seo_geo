# frozen_string_literal: true

require "uri"
require "nokogiri"

module SeoGeo
  module Audit
    # Pure checks over response bodies. Shared by {Runner}, {SeoGeo::Testing::Assertions} and the
    # RSpec matchers, so a test and the audit can never disagree. Each returns problem messages
    # (empty when fine).
    module Checks
      TITLE_MAX = 60
      DESCRIPTION_RANGE = (70..160)
      SITEMAP_NS = "http://www.sitemaps.org/schemas/sitemap/0.9"

      module_function

      # @param doc [HtmlDocument]
      # @return [Array<String>] problems with +<title>+ count (errors)
      def title_count(doc)
        count = doc.titles.size
        return [] if count == 1

        [count.zero? ? "no <title>" : "#{count} <title> elements (exactly one expected)"]
      end

      # @param doc [HtmlDocument]
      # @return [Array<String>] FAQPage questions or answers missing from the visible text
      def faq_visible(doc)
        text = doc.visible_text
        doc.faq_items.flat_map do |item|
          problems = []
          problems << "FAQ question not in visible text: #{item[:question].inspect}" unless text.include?(item[:question])
          problems << "FAQ answer not in visible text: #{item[:answer].inspect}" unless text.include?(item[:answer])
          problems
        end
      end

      # @param doc [HtmlDocument]
      # @return [Array<String>] unparsable blocks and nodes missing properties {JsonLd::REQUIRED} lists
      def json_ld(doc)
        nodes, problems = doc.json_ld
        nodes.each do |node|
          doc.types(node).each do |type|
            missing = JsonLd::REQUIRED.fetch(type, []).select { |key| blank?(node[key]) }
            problems << [type, node["@id"], "is missing #{missing.join(", ")}"].compact.join(" ") unless missing.empty?
          end
        end
        problems
      end

      # @param xml [String] sitemap.xml body
      # @param origin [String, nil] every +<loc>+ must start with it (e.g. "https://www.example.com/")
      # @return [Array(Array<String>, Array<String>, Symbol)] problems, +<loc>+ values, :urlset/:sitemapindex
      def sitemap(xml, origin: nil)
        doc = Nokogiri::XML(xml.to_s) { |options| options.strict.nonet }
        root = doc.root
        kind = root&.name&.to_sym
        unless %i[urlset sitemapindex].include?(kind) && root.namespace&.href == SITEMAP_NS
          return [["root element must be <urlset> or <sitemapindex> in #{SITEMAP_NS}"], [], kind]
        end

        locs = doc.xpath("//s:loc", "s" => SITEMAP_NS).map { |node| node.text.strip }
        problems = []
        problems << "sitemap lists no URL" if locs.empty?
        problems << "#{locs.size} URLs in one file (limit 50,000)" if locs.size > 50_000
        locs.each do |loc|
          problems << "<loc> #{loc} is not absolute" unless loc.match?(%r{\Ahttps?://}i)
          problems << "<loc> #{loc} is not under #{origin}" if origin && !same_origin?(loc, origin)
        end
        [problems, locs, kind]
      rescue Nokogiri::XML::SyntaxError => e
        [["sitemap is not well-formed XML: #{e.message.strip}"], [], nil]
      end

      # @param canonical [String, nil] canonical href
      # @param expected_origin [String] e.g. "https://www.example.com"
      # @return [Array<String>]
      def canonical_origin(canonical, expected_origin)
        return ["no <link rel=\"canonical\">"] if canonical.nil? || canonical.strip.empty?

        uri = URI.parse(canonical)
        actual = uri.host && "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless [80, 443].include?(uri.port)}"
        actual&.casecmp?(expected_origin.chomp("/")) ? [] : ["canonical #{canonical} is not on #{expected_origin}"]
      rescue URI::InvalidURIError
        ["canonical #{canonical.inspect} is not a valid URL"]
      end

      # @param url [String]
      # @param origin [String]
      # @return [Boolean] same scheme, host and effective port
      def same_origin?(url, origin)
        a = URI.parse(url)
        b = URI.parse(origin)
        a.host && b.host && a.scheme&.downcase == b.scheme&.downcase && a.host.casecmp?(b.host) && a.port == b.port
      rescue URI::InvalidURIError
        false
      end

      # @param value [Object]
      # @return [Boolean]
      def blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
      end
    end
  end
end
