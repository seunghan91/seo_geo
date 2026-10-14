# frozen_string_literal: true

require "date"
require "uri"

module SeoGeo
  module Sitemap
    # Renders the sitemap for one request host from {Registry#each_url}.
    #
    # Up to {MAX_URLS} URLs => one +<urlset>+ at /sitemap.xml. Above that, /sitemap.xml is a
    # +<sitemapindex>+ pointing at /sitemap-1.xml, /sitemap-2.xml, ... (sitemaps.org limit: 50,000 per file).
    # URLs {SeoGeo::Publication} rejects are dropped (robots-disallowed, excluded, declared noindex,
    # not opted in under +default_noindex+).
    #
    # @example
    #   xml = SeoGeo::Sitemap::Xml.new(SeoGeo.config, SeoGeo.sitemap, "www.example.com")
    #   xml.render(nil) # => String, or nil when the host has no sitemap
    class Xml
      MAX_URLS = 50_000
      XMLNS = "http://www.sitemaps.org/schemas/sitemap/0.9"

      # @param config [Configuration]
      # @param registry [Registry]
      # @param host [String] request host
      # @param max_urls [Integer] URLs per file (tests may lower it)
      def initialize(config, registry, host, max_urls: MAX_URLS)
        @config = config
        @registry = registry
        @host = host
        @max_urls = max_urls
        @policy = config.host_policy(host)
      end

      # @param page [Integer, nil] nil => /sitemap.xml; n => /sitemap-n.xml
      # @return [String, nil] XML, or nil when there is nothing to serve (=> 404)
      def render(page = nil)
        return nil unless @policy.sitemap

        page.nil? ? render_root : render_part(page)
      end

      # @return [Enumerator<Url>] URLs this host's sitemap lists
      def urls
        Enumerator.new do |yielder|
          @registry.each_url(@host, config: @config) { |url| yielder << url if listable?(url) }
        end
      end

      private

      def render_root
        head = urls.take(@max_urls + 1)
        return nil if head.empty?
        return urlset(head) if head.length <= @max_urls

        sitemap_index
      end

      def render_part(page)
        return nil unless page.is_a?(Integer) && page.positive?

        chunk = []
        split = false
        urls.each_with_index do |url, index|
          split = true if index == @max_urls
          next unless index / @max_urls == page - 1
          chunk << url
        end
        # Parts exist only when the root is an index; /sitemap-1.xml of a small site is a 404.
        split && !chunk.empty? ? urlset(chunk) : nil
      end

      def sitemap_index
        parts = []
        urls.each_slice(@max_urls) { |slice| parts << slice.filter_map { |url| url.lastmod && as_time(url.lastmod) }.max }
        origin = @config.origin_for(@host)
        body = parts.each_with_index.map do |lastmod, index|
          lines = ["  <sitemap>", "    <loc>#{escape("#{origin}/sitemap-#{index + 1}.xml")}</loc>"]
          lines << "    <lastmod>#{format_time(lastmod)}</lastmod>" if lastmod
          lines << "  </sitemap>"
          lines.join("\n")
        end
        document("sitemapindex", body)
      end

      def urlset(list)
        body = list.map do |url|
          lines = ["  <url>", "    <loc>#{escape(url.loc)}</loc>"]
          lines << "    <lastmod>#{format_time(url.lastmod)}</lastmod>" if url.lastmod
          lines << "    <changefreq>#{url.changefreq}</changefreq>" if url.changefreq
          lines << "    <priority>#{format("%.1f", url.priority)}</priority>" if url.priority
          lines << "  </url>"
          lines.join("\n")
        end
        document("urlset", body)
      end

      def document(root, body)
        [%(<?xml version="1.0" encoding="UTF-8"?>), %(<#{root} xmlns="#{XMLNS}">), *body, "</#{root}>", ""].join("\n")
      end

      # {SeoGeo::Publication} decides (robots disallow, exclusions, noindex declarations,
      # default_noindex) — the same predicate llms.txt and the head use.
      def listable?(url)
        # Registry#each_url already skipped entries without index: true under default_noindex.
        Publication.publishable?(@host, url.loc, config: @config, sitemap: @registry, check_host: false, declared_index: true)
      end

      # Dates stay dates (W3C "YYYY-MM-DD"); times become W3C datetimes.
      def format_time(value)
        return value.to_s if value.is_a?(String)
        return value.iso8601 if value.is_a?(Date) && !value.is_a?(DateTime)

        value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
      end

      def as_time(value)
        case value
        when DateTime then value.to_time
        when Date then Time.utc(value.year, value.month, value.day)
        when String then parse_time(value)
        else value.respond_to?(:to_time) ? value.to_time : nil
        end
      end

      def parse_time(value)
        Time.iso8601(value)
      rescue ArgumentError
        date = Date.iso8601(value) rescue nil # rubocop:disable Style/RescueModifier
        date && Time.utc(date.year, date.month, date.day)
      end

      def escape(text)
        text.to_s.encode(xml: :text)
      end
    end
  end
end
