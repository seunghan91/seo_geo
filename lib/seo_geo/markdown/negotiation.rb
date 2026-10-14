# frozen_string_literal: true

module SeoGeo
  module Markdown
    # Decides whether an +Accept+ header asks for Markdown.
    #
    # Markdown wins only when +text/markdown+ is named explicitly (wildcards never select it) with a
    # q-value above zero that is higher than the one +text/html+ gets, or equal to it and listed first.
    # Agents send +text/markdown, text/html;q=0.9+ or +text/markdown, text/html, *\/*+; browsers never
    # name text/markdown, so they keep getting HTML.
    module Negotiation
      module_function

      # @param accept [String, nil] raw Accept header
      # @return [Boolean]
      def markdown?(accept)
        ranges = parse(accept)
        markdown = ranges.find { |range| range[:type] == "text/markdown" }
        return false if markdown.nil? || markdown[:q] <= 0

        html = quality_for_html(ranges)
        return true if html.nil?

        markdown[:q] > html[:q] || (markdown[:q] == html[:q] && markdown[:index] < html[:index])
      end

      # @param accept [String, nil]
      # @return [Array<Hash>] +{type:, q:, index:}+ in header order
      def parse(accept)
        accept.to_s.split(",").each_with_index.filter_map do |part, index|
          type, *params = part.split(";").map(&:strip)
          next if type.nil? || type.empty?

          q = params.filter_map { |param| param[/\Aq\s*=\s*([0-9.]+)\z/i, 1] }.first
          { type: type.downcase, q: q ? q.to_f.clamp(0.0, 1.0) : 1.0, index: index }
        end
      end

      # The most specific range matching text/html (RFC 9110 §12.5.1).
      def quality_for_html(ranges)
        %w[text/html text/* */*].each do |type|
          found = ranges.find { |range| range[:type] == type }
          return found if found
        end
        nil
      end
    end
  end
end
