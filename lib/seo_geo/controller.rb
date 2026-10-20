# frozen_string_literal: true

module SeoGeo
  # Included into ActionController::Base by the engine (initializer "seo_geo.helpers").
  #
  # @example
  #   class PostsController < ApplicationController
  #     def show
  #       @post = Post.find(params[:id])
  #       seo title: @post.title, description: @post.summary, image: @post.cover_url, type: "article"
  #     end
  #   end
  #
  #   class LandingController < ApplicationController
  #     def show
  #       render inertia: "Home", props: { seo: seo_geo_page(:home).props }
  #     end
  #   end
  module Controller
    SEO_KEYS = Meta::State.members.freeze

    def self.included(base)
      base.helper_method :seo_geo_state, :seo_geo_page, :seo_geo_markdown_available? if base.respond_to?(:helper_method)
    end

    # Sets head values for this request. Later calls merge into earlier ones; +json_ld:+ appends.
    #
    # @param title [String] page title without the site suffix (title_template adds it)
    # @param description [String]
    # @param image [String, Hash] absolute or root-relative OG image URL (or +{url:}+)
    # @param noindex [Boolean] true => robots noindex
    # @param index [Boolean] true => opt this action into indexing when +default_noindex+ is on
    # @param canonical [String, false] path or URL to canonicalize; false omits the canonical link and hreflang
    # @param page [Symbol, Page] page copy (title/description/FAQ JSON-LD defaults)
    # @param type [String] og:type (default "website")
    # @param published_time [Time, Date, String] ISO 8601 article publication time (type: "article" only)
    # @param modified_time [Time, Date, String] ISO 8601 article modification time (type: "article" only)
    # @param markdown [Boolean] false hides the Markdown alternate link
    # @param json_ld [Hash, JsonLd, Array] extra JSON-LD nodes
    # @return [Meta::State]
    def seo(**options)
      unknown = options.keys - SEO_KEYS
      raise ArgumentError, "unknown seo option(s): #{unknown.join(", ")} (known: #{SEO_KEYS.join(", ")})" unless unknown.empty?

      extra_json_ld = options.delete(:json_ld)
      options.each { |name, value| seo_geo_state[name] = value }
      seo_geo_state.json_ld.concat(extra_json_ld.is_a?(Array) ? extra_json_ld.flatten : [extra_json_ld]) if extra_json_ld
      seo_geo_state
    end

    # Fetches the page copy and uses it for this request's head (title, description, FAQPage).
    # The return value feeds the crawler fallback body and Inertia props: +seo_geo_page(:home).props+.
    # @param key [Symbol, String]
    # @param locale [Symbol, String, nil]
    # @return [Page]
    def seo_geo_page(key, locale: nil)
      page = SeoGeo.page(key, locale: locale)
      seo_geo_state.page = page
      page
    end

    # Whether this action answers Markdown requests; {SeoGeo::Markdownable} overrides it per action.
    # +seo_geo_head+ advertises the Markdown alternate only when this is true.
    # @return [Boolean]
    def seo_geo_markdown_available?
      false
    end

    # @return [Meta::State]
    def seo_geo_state
      @seo_geo_state ||= Meta::State.new
    end
  end
end
