# frozen_string_literal: true

module SeoGeo
  module Audit
    # Audits deployed responses without booting Rails or changing the application's configuration.
    class Remote < Runner
      # @param urls [Array<String>, String] explicit pages/origins; each origin is audited once
      # @param io [#puts, nil] report destination; nil suppresses output
      # @param config [Configuration, nil] optional comparison policy, used only for known hosts
      # @param max_pages [Integer] sitemap pages per origin
      # @param delay [Numeric] HTTP request spacing in seconds
      # @param timeout [Numeric] HTTP timeouts in seconds
      # @param format [Symbol, String] text or json
      # @return [Report]
      def self.run(urls, io: $stdout, config: SeoGeo.config, max_pages: 200, delay: 0.5, timeout: 10, format: :text)
        targets = Array(urls).map { |url| HttpFetcher.http_uri(url) }
        raise ArgumentError, "at least one audit URL is required" if targets.empty?

        transport = HttpFetcher.new(origin: targets.first.to_s, delay: delay, timeout: timeout)
        report = Report.new
        targets.group_by { |uri| "#{uri.scheme}://#{uri.authority}" }.each do |origin, pages|
          result = new(origin: origin, urls: pages.map(&:to_s), config: config,
                       max_pages: max_pages, delay: delay, timeout: timeout, fetcher: transport).run
          report.findings.concat(result.findings)
          result.stats.each { |name, count| report.stats[name] += count }
        end
        io.puts(format.to_s.casecmp?("json") ? report.to_json : report.to_s) if io
        report
      end

      # @param origin [String] one HTTP(S) origin
      # @param urls [Array<String>] explicitly requested pages on that origin
      # @param config [Configuration, nil] optional existing configuration
      # @param max_pages [Integer] maximum sitemap pages
      # @param delay [Numeric] delay between HTTP requests
      # @param timeout [Numeric] HTTP timeouts
      # @param fetcher [HttpFetcher, nil] shared serial transport across origins
      def initialize(origin:, urls:, config: nil, max_pages: 200, delay: 0.5, timeout: 10, fetcher: nil)
        @origin = origin
        @urls = urls.uniq
        host = URI.parse(origin).host.downcase
        @comparison_config = config if config&.known_hosts&.include?(host)
        observed = @comparison_config || Configuration.new.tap do |settings|
          settings.canonical_origin = origin
          settings.environment = "production"
        end
        @audited_pages = []
        @remote_findings = {}
        super(app: nil, config: observed, sitemap: Sitemap::Registry.new, hosts: [host], max_pages: max_pages,
              fetcher: fetcher || HttpFetcher.new(origin: origin, delay: delay, timeout: timeout))
      end

      private

      def origin_for(_host)
        @origin
      end

      def audit_host(host)
        super
        @urls.each do |url|
          audit_page(host, url, from_sitemap: false) unless @audited_pages.include?(url)
        end
      end

      def audit_page(host, url, **options)
        @audited_pages << url
        super
      end

      def sitemap_urls(host)
        super.select { |url| Checks.same_origin?(url, @origin) }
      end

      def check_robots_allows(host, url, evaluator)
        return super if @comparison_config
        return if evaluator.allowed?("*", request_path(url))

        error(host, url, "sitemap.robots_blocked", "listed in sitemap.xml but robots.txt disallows it for *")
      end

      def fetch(host, path, headers = {}, **options)
        response = super(host, "#{@origin}#{path}", headers, **options)
        @fetcher.chain.each do |hop|
          directives = RobotsDirectives.parse_header(hop[:headers]["x-robots-tag"])
          if directives.noindex? || directives.scoped.keys.any? { |bot| directives.noindex?(bot) }
            remote_finding(:error, host, hop[:url], "page.x_robots_noindex", "X-Robots-Tag contains noindex")
          end
        end
        hops = @fetcher.chain.size - 1
        if hops > 1
          trace = @fetcher.chain.map { |hop| "#{hop[:status]} #{hop[:url]}" }.join(" -> ")
          remote_finding(:warning, host, path, "page.redirect_chain", "#{hops} redirect hops: #{trace}")
        end
        if @fetcher.redirect_error
          remote_finding(:error, host, path, "page.redirect", @fetcher.redirect_error)
        end
        if path == "/robots.txt" && @comparison_config && response.status == 200 &&
           response.body != Robots.new(@comparison_config, host).to_s
          remote_finding(:warning, host, path, "robots.mismatch", "robots.txt differs from the configured rendering for this host")
        end
        response
      end

      def remote_finding(severity, host, url, check, message)
        key = [host, url, check]
        return if @remote_findings[key]

        @remote_findings[key] = true
        @report.add(severity, check, message, host: host, url: url)
      end
    end
  end
end
