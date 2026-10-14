# frozen_string_literal: true

require "uri"
require "set"

module SeoGeo
  # Builds /llms.txt (https://llmstxt.org/) and /llms-full.txt for one request host.
  #
  # llms.txt: +# site.name+, +> site.description+, optional {LlmsTxtOptions#details}, then one H2 per
  # section with +- [title](url): description+ lines and +## Optional+ last. Page links point at the
  # page's Markdown (+.md+) when {MarkdownOptions#enabled}. Links come from {Configuration#llms_txt};
  # when none are declared, the host's static sitemap paths are listed.
  #
  # llms-full.txt (community convention, not in the llmstxt.org text): the same header followed by
  # every listed page's {Page#to_markdown}, headings demoted one level under one H1.
  #
  # Both are served only for hosts whose sitemap is on ({HostPolicy#sitemap}); otherwise nil (=> 404).
  class LlmsTxt
    OPTIONAL_SECTION = "Optional"

    # @param config [Configuration]
    # @param host [String] request host
    # @param pages [PageRegistry]
    # @param sitemap [Sitemap::Registry] fallback link source
    def initialize(config, host, pages: SeoGeo.pages, sitemap: SeoGeo.sitemap)
      @config = config
      @host = host
      @pages = pages
      @sitemap = sitemap
      @options = config.llms_txt
      @policy = config.host_policy(host)
    end

    # @return [String, nil] llms.txt body, nil when not served on this host
    def to_s
      return nil unless served?

      parts = header
      sections.each do |name, lines|
        parts << "## #{name}\n\n#{lines.join("\n")}"
      end
      "#{parts.join("\n\n")}\n"
    end

    # @return [String, nil] llms-full.txt body, nil when not served or no page is listed
    def full
      return nil unless served? && @options.full

      page_links = links.select(&:page)
      return nil if page_links.empty?

      parts = header
      page_links.each do |item|
        markdown = page_for(item).to_markdown.gsub(/^(#+) /) { "##{Regexp.last_match(1)} " }
        parts << "---\n\nSource: #{absolute(item.path)}\n\n#{markdown.strip}"
      end
      "#{parts.join("\n\n")}\n"
    end

    private

    def served?
      @options.enabled && @policy.sitemap
    end

    def header
      name = present(@config.site.name) || @config.canonical_host || @policy.host
      parts = ["# #{name}"]
      description = present(@config.site.description)
      parts << "> #{description.gsub(/\s+/, " ")}" if description
      details = present(@options.details)
      parts << details_markdown(details) if details
      parts
    end

    # @return [Array<Array(String, Array<String>)>] section name => link lines, Optional last
    def sections
      grouped = links.group_by { |item| item.optional ? OPTIONAL_SECTION : (item.section || @options.default_section) }
      optional = grouped.delete(OPTIONAL_SECTION)
      grouped = grouped.to_a
      grouped << [OPTIONAL_SECTION, optional] if optional
      grouped.map { |name, items| [name, items.map { |item| line(item) }] }
    end

    def line(item)
      page = item.page && page_for(item)
      title = item.title || page&.title || page&.heading || item.path
      description = item.description || page&.description
      url = absolute(item.path)
      url = markdown_url(url) if item.markdown_link?(@config) && same_origin?(URI.parse(url))
      text = "- [#{title.to_s.gsub(/[\[\]]/) { |char| "\\#{char}" }}](#{url})"
      description ? "#{text}: #{description.to_s.gsub(/\s+/, " ").strip}" : text
    end

    def links
      @links ||= begin
        declared = @options.links.select { |item| for_host?(item.hosts) }
        (@options.links.empty? ? sitemap_links : declared).select { |item| publishable?(item.path) }
      end
    end

    def sitemap_links
      @sitemap.entries.select { |entry| entry.static? && entry.for_host?(@host, @config) && !@sitemap.excluded?(entry.source) }
              .map do |entry|
        LlmsTxtOptions::Link.new(page: nil, title: nil, path: entry.source, description: nil, section: nil,
                                 optional: false, hosts: nil, markdown: entry.markdown)
      end
    end

    # llms.txt and llms-full.txt list only what {SeoGeo::Publication} allows (the sitemap.xml and
    # head rule: robots disallow, exclusions, noindex declarations, default_noindex). Links to other
    # origins are not ours to judge and pass through.
    def publishable?(path)
      if path.match?(%r{\Ahttps?://}i)
        return true unless same_origin?(URI.parse(path))
      end
      # /x.md (also /x.md?q) is the Markdown form of /x (Markdown::PathSuffix), so it is published only when /x is.
      # The query stays for robots rules (Disallow: /x?preview=1); declarations drop it themselves.
      page_path = RobotsPath.html_target(path, markdown: @config.markdown.suffix_urls?)
      Publication.publishable?(@host, page_path, config: @config, sitemap: @sitemap, check_host: false,
                                                 declared_index: indexed_by_sitemap?(page_path))
    rescue URI::InvalidURIError
      false
    end

    def same_origin?(uri)
      origin = URI.parse(@config.origin_for(@host))
      uri.host && uri.host.casecmp?(origin.host) && uri.scheme.casecmp?(origin.scheme) && uri.port == origin.port
    end

    # Under default_noindex, records of a collection added with index: true are declared indexable too;
    # only sitemap.xml knows their paths, so ask it (enumerated once per llms.txt render).
    def indexed_by_sitemap?(path)
      return false unless @config.default_noindex

      @indexed_paths ||= Sitemap::Xml.new(@config, @sitemap, @host).urls
                                     .to_set { |url| RobotsPath.path(url.loc) }
      @indexed_paths.include?(RobotsPath.path(path))
    end

    def for_host?(hosts)
      wanted = hosts ? hosts.map(&:downcase) : [@config.canonical_host]
      wanted.include?(@policy.host)
    end

    def page_for(item)
      @pages.fetch(item.page, locale: @config.site.default_locale)
    end

    def absolute(path)
      return path if path.match?(%r{\Ahttps?://})

      @config.canonical_url("#{@config.origin_for(@host)}#{path}")
    end

    # "/" => "/index.md", "/pricing" => "/pricing.md" (llmstxt.org convention); query dropped.
    def markdown_url(url)
      uri = URI.parse(url)
      path = uri.path.to_s
      path = path.empty? || path.end_with?("/") ? "#{path.chomp("/")}/index.md" : "#{path}.md"
      uri.path = path
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      url
    end

    # Details are free Markdown (paragraphs, lists, headings). In llms.txt the single H1 is the site name and H2s are
    # link sections, so H1/H2 headings in details are demoted to H3 (outside fenced code); H3+ stay as written.
    def details_markdown(text)
      fenced = false
      text.strip.lines.map do |line|
        fenced = !fenced if line.start_with?("```", "~~~")
        fenced ? line : line.sub(/\A\#{1,2}(?=\s)/, "###")
      end.join
    end

    def present(value)
      value.nil? || value.to_s.strip.empty? ? nil : value.to_s
    end
  end
end
