# frozen_string_literal: true

module SeoGeo
  # Static page body for crawlers that do not run JavaScript (GPTBot, ClaudeBot, PerplexityBot, Yeti...)
  # on client-rendered pages (Inertia, SPA). It renders the same {Page} copy as the Inertia props and
  # the FAQPage JSON-LD. The head snippet from +seo_geo_head+ hides it while JavaScript runs and shows it
  # again when the app has not called +window.SeoGeo.mounted()+ within five seconds.
  #
  # Markup lives in +app/views/seo_geo/fallback/_body.html.erb+ and +_faq.html.erb+; an app overrides
  # it by adding the same paths under its own +app/views+.
  module CrawlerFallback
    # View helpers, included into ActionView by the engine (initializer "seo_geo.helpers").
    module Helper
      # Extra crawler-visible HTML goes at the end of +<main>+, from the block and/or
      # +content_for(:seo_geo_fallback_extra)+ (block first).
      #
      # @example
      #   <%= seo_geo_fallback_body(:home) do %>
      #     <p><a href="/pricing">Pricing</a></p>
      #   <% end %>
      # @param key [Symbol, String, Page] page key or a fetched page
      # @param locale [Symbol, String, nil]
      # @return [ActiveSupport::SafeBuffer] +<main data-seo-fallback>+ with heading, intro, features, FAQ, extra
      def seo_geo_fallback_body(key, locale: nil, &block)
        extra = safe_join([block && capture(&block), content_for?(:seo_geo_fallback_extra) ? content_for(:seo_geo_fallback_extra) : nil].compact)
        render(partial: "seo_geo/fallback/body", locals: { page: seo_geo_fallback_page(key, locale), extra: extra })
      end

      # The FAQ section alone, for server-rendered (ERB) pages that show the FAQ themselves; it is the
      # same text as the FAQPage JSON-LD.
      # @param key [Symbol, String, Page]
      # @param locale [Symbol, String, nil]
      # @return [ActiveSupport::SafeBuffer]
      def seo_geo_faq(key, locale: nil)
        render(partial: "seo_geo/fallback/faq", locals: { page: seo_geo_fallback_page(key, locale) })
      end

      private

      def seo_geo_fallback_page(key, locale)
        key.is_a?(Page) ? key : SeoGeo.page(key, locale: locale)
      end
    end
  end
end
