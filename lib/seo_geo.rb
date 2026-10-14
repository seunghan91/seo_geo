# frozen_string_literal: true

require_relative "seo_geo/version"
require_relative "seo_geo/crawlers"
require_relative "seo_geo/safe_regexp"
require_relative "seo_geo/robots_path"
require_relative "seo_geo/robots_directives"
require_relative "seo_geo/undeclared_host"
require_relative "seo_geo/configuration"
require_relative "seo_geo/sitemap/registry"
require_relative "seo_geo/page"
# Head, JSON-LD, crawler fallback
require_relative "seo_geo/json_ld"
require_relative "seo_geo/meta"
require_relative "seo_geo/crawler_fallback"
require_relative "seo_geo/controller"
# Robots, sitemap, llms.txt
require_relative "seo_geo/robots"
require_relative "seo_geo/sitemap/xml"
require_relative "seo_geo/llms_txt"
# Markdown, IndexNow, OG image
require_relative "seo_geo/markdown/negotiation"
require_relative "seo_geo/markdown/document"
require_relative "seo_geo/markdown/path_suffix"
require_relative "seo_geo/markdownable"
require_relative "seo_geo/index_now"
require_relative "seo_geo/model"
require_relative "seo_geo/og_image/renderer"
require_relative "seo_geo/og_image/ferrum_backend"
# Noindex path matching, robots evaluator, audit, bot verification
require_relative "seo_geo/path_match"
require_relative "seo_geo/publication"
require_relative "seo_geo/robots/evaluator"
require_relative "seo_geo/audit"
require_relative "seo_geo/bot_verifier"

# SEO and GEO (Generative Engine Optimization: visibility in AI search and assistants) for Rails.
# Not a geolocation library.
module SeoGeo
  class << self
    # @return [Configuration]
    def config
      @config ||= Configuration.new
    end

    # @yieldparam config [Configuration]
    # @return [Configuration]
    def configure
      yield config
      config
    end

    # @return [Sitemap::Registry]
    def sitemap
      @sitemap ||= Sitemap::Registry.new
    end

    # @return [PageRegistry]
    def pages
      @pages ||= PageRegistry.new
    end

    # @param key [Symbol, String]
    # @param locale [Symbol, String, nil]
    # @return [Page]
    def page(key, locale: nil)
      pages.fetch(key, locale: locale)
    end

    # Replaces configuration and registries with fresh instances (tests).
    # @return [void]
    def reset!
      @config = Configuration.new
      @sitemap = Sitemap::Registry.new
      @pages = PageRegistry.new
    end
  end
end

require_relative "seo_geo/engine" if defined?(Rails::Engine)
