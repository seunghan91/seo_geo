# frozen_string_literal: true

module SeoGeo
  # One answer to "may this path be published to crawlers on this host?". sitemap.xml, llms.txt,
  # llms-full.txt and the head's robots meta all ask it, so they cannot disagree.
  #
  # A path is publishable on a host when all hold:
  # - the host serves a sitemap ({HostPolicy#sitemap}: declared/canonical, indexable, indexable environment);
  # - robots.txt does not disallow it for the host (RFC 9309 longest match over the host's
  #   +allow+/+disallow+ prefixes, Allow wins a tie);
  # - it is not excluded with {Sitemap::Registry#exclude};
  # - it is not declared noindex ({Configuration#noindex_paths}, +sitemap.add path, noindex: true+);
  # - under {Configuration#default_noindex}, it is declared indexable (+sitemap.add path, index: true+ —
  #   the registry counterpart of a controller's +seo index: true+).
  #
  # Request-time +seo noindex: true+ is invisible here; +rake seo_geo:audit+ reports such pages
  # (+sitemap.noindex+).
  module Publication
    module_function

    # @param host [String] request host
    # @param path [String] path or absolute URL; robots rules see the {RobotsPath.target} (query kept),
    #   declarations the {RobotsPath.path}. A +.md+ URL is judged as the page it is the Markdown of — callers
    #   pass {RobotsPath.html_path} for those.
    # @param config [Configuration]
    # @param sitemap [Sitemap::Registry]
    # @param check_host [Boolean] false skips the host sitemap check (callers that already did it)
    # @param declared_index [Boolean] true when the caller already knows the entry was added with
    #   +index: true+ (sitemap.xml, whose Registry#each_url only yields such entries under default_noindex)
    # @return [Boolean]
    def publishable?(host, path, config: SeoGeo.config, sitemap: SeoGeo.sitemap, check_host: true, declared_index: false)
      policy = config.host_policy(host)
      return false if check_host && !policy.sitemap
      return false if robots_blocked?(policy, path)
      return false if sitemap.excluded?(path)
      return false if declared_noindex?(path, config: config, sitemap: sitemap)

      !config.default_noindex || declared_index || declared_index?(host, path, config: config, sitemap: sitemap)
    end

    # Head robots meta: a declared-noindex path is noindex even when the controller calls +seo index: true+.
    # Declarations apply on every host (restricting is the safe side).
    # @param path [String]
    # @return [Boolean]
    def declared_noindex?(path, config: SeoGeo.config, sitemap: SeoGeo.sitemap)
      config.noindex_path?(path) || sitemap.noindex?(path)
    end

    # Head robots meta under +default_noindex+: an +index: true+ entry for this host covers the path — a static
    # path, or a collection whose +match:+ accepts it ({Sitemap::Entry#covers?}). The same answer
    # sitemap.xml and llms.txt use, so the head cannot be noindex for a listed page on one host and indexable
    # on another.
    # @param host [String] request host
    # @param path [String]
    # @return [Boolean]
    def declared_index?(host, path, config: SeoGeo.config, sitemap: SeoGeo.sitemap)
      sitemap.index?(path, host: host, config: config)
    end

    # RFC 9309 §2.2.2 over the host policy's lists, through the same matcher as {Robots::Evaluator}.
    # @param policy [HostPolicy]
    # @param path [String]
    # @return [Boolean]
    def robots_blocked?(policy, path)
      RobotsPath.blocked?(policy.allow, policy.disallow, path)
    end
  end
end
