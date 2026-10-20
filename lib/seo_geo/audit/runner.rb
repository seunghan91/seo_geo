# frozen_string_literal: true

require "uri"
require "rack"
require "rack/mock"
require "securerandom"

module SeoGeo
  module Audit
    # Requests the application in-process (Rack, no network, no server) for every known host and
    # collects {Finding}s. Outside an indexable environment the run temporarily switches
    # {Configuration#environment} to the first of +indexable_environments+, so a development
    # checkout is audited as production would serve it.
    #
    # Per host: robots.txt (200), sitemap.xml (valid; 404 when the policy has none), every sitemap URL
    # (up to +max_pages+) and "/", llms.txt and its links. Per HTML page: one +<title>+ (length, unique),
    # description length, canonical origin, noindex vs sitemap, robots vs sitemap, JSON-LD parse and
    # required properties, FAQPage text visible, +<html lang>+, Markdown alternate (+.md+ and
    # +Accept: text/markdown+ with +Vary: Accept+), verification metas. Plus {StaticScan}.
    #
    # @example
    #   report = SeoGeo::Audit::Runner.new(app: Rails.application, root: Rails.root).run
    #   puts report
    class Runner
      MARKDOWN_TYPE = %r{\Atext/markdown}i

      # @param app [#call] Rack application
      # @param config [Configuration]
      # @param sitemap [Sitemap::Registry]
      # @param root [String, Pathname, nil] application root for {StaticScan}; nil skips it
      # @param hosts [Array<String>, nil] hosts to audit; nil => {Configuration#known_hosts}
      # @param max_pages [Integer] sitemap URLs fetched per host
      # @param fetcher [#fetch, nil] transport; nil uses {RackFetcher}
      def initialize(app:, config: SeoGeo.config, sitemap: SeoGeo.sitemap, root: nil, hosts: nil, max_pages: 200, fetcher: nil)
        @app = app
        @fetcher = fetcher || RackFetcher.new(app: app, config: config)
        @config = config
        @sitemap = sitemap
        @root = root
        @hosts = hosts
        @max_pages = max_pages
        @report = Report.new
        @descriptions = Hash.new { |hash, key| hash[key] = [] }
        @titles = Hash.new { |hash, key| hash[key] = [] }
      end

      # @return [Report]
      def run
        StaticScan.new(@root).call(@report) if @root
        unmatched_index_collections
        with_indexable_environment do
          (@hosts || @config.known_hosts).each { |host| audit_host(host.to_s.downcase) }
        end
        duplicate_titles
        duplicate_descriptions
        @report
      end

      private

      def audit_host(host)
        check_soft_404(host)
        policy = @config.host_policy(host)
        robots = fetch(host, "/robots.txt")
        evaluator = nil
        if robots.status == 200
          evaluator = Robots::Evaluator.new(robots.body)
        else
          error(host, "/robots.txt", "robots.status", "robots.txt returned #{robots.status}")
        end

        urls = policy.sitemap ? sitemap_urls(host) : expect_no_sitemap(host)
        pages = urls.first(@max_pages)
        @report.stats["skipped"] += urls.size - pages.size if urls.size > pages.size
        pages.each do |url|
          check_robots_allows(host, url, evaluator) if evaluator
          audit_page(host, url, from_sitemap: true)
        end
        home = "#{origin_for(host)}/"
        unless pages.any? { |url| same_page?(url, home) }
          audit_page(host, home, from_sitemap: false, full: policy.sitemap)
        end
        audit_llms(host) if policy.sitemap && @config.llms_txt.enabled
      end

      def sitemap_urls(host)
        response = fetch(host, "/sitemap.xml")
        unless response.status == 200
          error(host, "/sitemap.xml", "sitemap.status", "sitemap.xml returned #{response.status} but the host policy has a sitemap")
          return []
        end

        origin = "#{origin_for(host)}/"
        problems, locs, kind = Checks.sitemap(response.body, origin: origin)
        problems.each { |message| error(host, "/sitemap.xml", "sitemap.valid", message) }
        return locs unless kind == :sitemapindex

        locs.flat_map do |part|
          part_response = fetch(host, request_path(part))
          part_problems, part_locs, = Checks.sitemap(part_response.body, origin: origin)
          part_problems.each { |message| error(host, part, "sitemap.valid", message) }
          part_locs
        end
      end

      def expect_no_sitemap(host)
        response = fetch(host, "/sitemap.xml")
        if response.status == 200
          error(host, "/sitemap.xml", "sitemap.unexpected", "sitemap.xml is served but the host policy says no sitemap")
        end
        []
      end

      def check_robots_allows(host, url, evaluator)
        path = request_path(url)
        # Groups the configuration denies on purpose (crawlers.training = :deny, overrides) are not problems.
        agents = (["*"] + (evaluator.agents - ["*"])).uniq.reject { |agent| @config.crawlers.policy_for(agent) == :deny }
        blocked = agents.reject { |agent| evaluator.allowed?(agent, path) }
        return if blocked.empty?

        error(host, url, "sitemap.robots_blocked", "listed in sitemap.xml but robots.txt disallows it for #{blocked.join(", ")}")
      end

      # +full: false+ (hosts without a sitemap, e.g. aliases): status, title count and canonical only.
      def audit_page(host, url, from_sitemap:, full: true)
        response = fetch(host, request_path(url))
        @report.stats["pages"] += 1
        unless response.status == 200
          severity = from_sitemap || response.status >= 400 ? :error : :warning
          @report.add(severity, "page.status", "returned #{response.status}#{location(response)}", host: host, url: url)
          return
        end
        return unless response.content_type.to_s.include?("html")

        doc = HtmlDocument.new(response.body)
        return check_canonical(host, url, doc) unless full

        noindex = doc.noindex?(response.headers["x-robots-tag"])
        error(host, url, "sitemap.noindex", "listed in sitemap.xml but the page is noindex") if noindex && from_sitemap
        check_title_and_description(host, url, doc, noindex)
        check_canonical(host, url, doc)
        Checks.json_ld(doc).each { |message| error(host, url, "json_ld", message) }
        Checks.faq_visible(doc).each { |message| error(host, url, "faq.visible", message) }
        warning(host, url, "html.lang", "<html> has no lang attribute") unless doc.html_lang
        check_verification(host, url, doc) if same_page?(url, "#{@config.canonical_origin}/")
        check_markdown(host, url, doc) if markdown_expected?(url, doc)
      end

      def check_canonical(host, url, doc)
        Checks.title_count(doc).each { |message| error(host, url, "title.count", message) }
        expected = URI.parse(@config.canonical_url(url))
        Checks.canonical_origin(doc.canonical, "#{expected.scheme}://#{expected.host}#{port_suffix(expected)}").each do |message|
          error(host, url, "canonical", message)
        end
      end

      def check_title_and_description(host, url, doc, noindex)
        title = doc.title
        if title
          warning(host, url, "title.length", "title is #{title.length} characters (> #{Checks::TITLE_MAX})") if title.length > Checks::TITLE_MAX
          @titles[[host, title]] << url unless noindex
        end
        description = doc.description.to_s.strip
        @descriptions[[host, description]] << url unless noindex || description.empty?
        if description.empty?
          warning(host, url, "description.missing", "no meta description")
        elsif !Checks::DESCRIPTION_RANGE.cover?(description.length)
          warning(host, url, "description.length",
                  "description is #{description.length} characters (#{Checks::DESCRIPTION_RANGE.min}–#{Checks::DESCRIPTION_RANGE.max} expected)")
        end
      end

      def check_verification(host, url, doc)
        @config.verification.meta_tags.each do |name, value|
          next if doc.meta_content(name) == value

          error(host, url, "verification", "<meta name=\"#{name}\"> missing or different from the configured token")
        end
      end

      # Pages registered with +markdown: false+ are not checked for Markdown (they do not serve it).
      def markdown_expected?(url, doc)
        @config.markdown.suffix_urls? && doc.markdown_alternate && !@sitemap.markdown_disabled?(request_path(url))
      end

      def check_markdown(host, url, doc)
        markdown_url = doc.markdown_alternate
        dot_md = fetch(host, request_path(markdown_url))
        unless dot_md.status == 200 && dot_md.content_type.to_s.match?(MARKDOWN_TYPE)
          error(host, markdown_url, "markdown.url", "advertised Markdown URL returned #{dot_md.status} #{dot_md.content_type}")
        end

        negotiated = fetch(host, request_path(url), { "HTTP_ACCEPT" => "text/markdown" })
        unless negotiated.status == 200 && negotiated.content_type.to_s.match?(MARKDOWN_TYPE)
          error(host, url, "markdown.accept", "page advertises Markdown but Accept: text/markdown returned " \
                                              "#{negotiated.status} #{negotiated.content_type} (include SeoGeo::Markdownable " \
                                              "or pass seo markdown: false)")
          return
        end
        vary = negotiated.headers["vary"].to_s.split(",").map { |value| value.strip.downcase }
        error(host, url, "markdown.vary", "Markdown response has no Vary: Accept") unless vary.include?("accept")
      end

      def audit_llms(host)
        response = fetch(host, "/llms.txt")
        unless response.status == 200
          error(host, "/llms.txt", "llms.status", "llms.txt returned #{response.status}")
          return
        end

        origins = [origin_for(host), @config.canonical_origin].uniq
        response.body.scan(/\]\((https?:\/\/[^)\s]+)\)/).flatten.uniq.each do |link|
          next unless origins.any? { |origin| link.start_with?("#{origin}/") || link == origin }

          target = URI.parse(link)
          link_host = target.host.to_s.downcase
          link_response = fetch(link_host, request_path(link))
          @report.stats["llms_links"] += 1
          unless link_response.status == 200
            error(host, link, "llms.link", "llms.txt link returned #{link_response.status}#{location(link_response)}")
            next
          end
          # .md links exist only for entries with markdown: true (or nil + markdown.enabled); they are served
          # by SeoGeo::Markdown::PathSuffix + Markdownable. A 406 above means the action is not markdownable.
          next unless target.path.to_s.end_with?(".md") && !link_response.content_type.to_s.match?(MARKDOWN_TYPE)

          error(host, link, "llms.markdown", "llms.txt links the .md form but it returned #{link_response.content_type} " \
                                             "(pass markdown: false to llms_txt.page/link for non-Markdownable actions)")
        end
      end

      def duplicate_titles
        @titles.each do |(host, title), urls|
          next if urls.uniq.size < 2

          warning(host, urls.first, "title.duplicate", "title #{title.inspect} is shared by #{urls.uniq.size} URLs: #{urls.uniq.first(5).join(", ")}")
        end
      end

      def duplicate_descriptions
        @descriptions.each do |(host, description), urls|
          next if urls.uniq.size < 2

          warning(host, urls.first, "description.duplicate",
                  "description #{description.inspect} is shared by #{urls.uniq.size} URLs: #{urls.uniq.first(5).join(', ')}")
        end
      end

      def check_soft_404(host)
        path = "/seo-geo-audit-#{SecureRandom.hex(8)}"
        response = fetch(host, path, expected_missing: true)
        error(host, path, "page.soft_404", "unknown path returned #{response.status} (expected a missing-page response)") if (200..299).cover?(response.status)
      end

      def origin_for(host)
        @config.origin_for(host)
      end

      # @return [Rack::MockResponse]
      def fetch(host, path, headers = {}, expected_missing: false)
        response = @fetcher.fetch(host, path, headers)
        if response.status == 403 && host_blocked?(host, response)
          error(host, path, "host_authorization", "Rails HostAuthorization blocked Host: #{URI.parse(origin_for(host)).authority}; run it through " \
                                                  "`bin/rails seo_geo:audit` (or set SEO_GEO_AUDIT=1 before boot, e.g. for " \
                                                  "bin/rails runner) so seo_geo allows its hosts outside production, or " \
                                                  "add #{host.inspect} to config.hosts")
        end
        response
      rescue StandardError => e
        # Test/development apps can raise their configured 404 exceptions instead of rendering a response.
        if expected_missing && defined?(ActionDispatch::ExceptionWrapper) &&
           ActionDispatch::ExceptionWrapper.status_code_for_exception(e.class.name) == 404
          return Rack::MockResponse.new(404, {}, [])
        end

        error(host, path, "exception", "#{e.class}: #{e.message.lines.first.to_s.strip}")
        Rack::MockResponse.new(500, {}, [])
      end

      # Rails HostAuthorization answers 403 with an empty body unless detailed exceptions are on, so ask the
      # app's own config.hosts as well as reading the "Blocked hosts" page.
      def host_blocked?(host, response)
        return true if response.body.include?("Blocked host")
        return false unless @app.respond_to?(:config) && @app.config.respond_to?(:hosts) && !@app.config.hosts.empty?
        return false unless defined?(ActionDispatch::HostAuthorization::Permissions)

        !ActionDispatch::HostAuthorization::Permissions.new(@app.config.hosts).allows?(host)
      end

      def with_indexable_environment
        return yield if @config.indexable_environment?

        saved = @config.environment
        begin
          @config.environment = @config.indexable_environments.first.to_s
          @report.stats["audited as #{@config.environment}"] = 1
          yield
        ensure
          @config.environment = saved
        end
      end

      def request_path(url)
        uri = URI.parse(url)
        path = uri.path.to_s.empty? ? "/" : uri.path
        uri.query ? "#{path}?#{uri.query}" : path
      rescue URI::InvalidURIError
        url
      end

      def same_page?(url_a, url_b)
        URI.parse(url_a).then { |a| [a.host, a.path.to_s.empty? ? "/" : a.path] } ==
          URI.parse(url_b).then { |b| [b.host, b.path.to_s.empty? ? "/" : b.path] }
      rescue URI::InvalidURIError
        false
      end

      def port_suffix(uri)
        [80, 443].include?(uri.port) ? "" : ":#{uri.port}"
      end

      def location(response)
        target = response.headers["location"]
        target ? " (→ #{target})" : ""
      end

      # Under default_noindex a collection added with index: true lists its records, but without match: the head
      # cannot tell a record path belongs to it, so the page stays noindex unless the controller says
      # +seo index: true+. The page audit then reports sitemap.noindex; this names the cause.
      def unmatched_index_collections
        return unless @config.default_noindex

        @sitemap.unmatched_index_collections.each do |entry|
          @report.add(:warning, "sitemap.collection_index",
                      "collection #{entry.source.class} is added with index: true but no match:, so its record pages " \
                      "are noindex unless their controller calls seo index: true (add match: ->(path) { ... })")
        end
      end

      def error(host, url, check, message)
        @report.add(:error, check, message, host: host, url: url)
      end

      def warning(host, url, check, message)
        @report.add(:warning, check, message, host: host, url: url)
      end
    end
  end
end
