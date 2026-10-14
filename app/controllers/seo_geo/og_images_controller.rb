# frozen_string_literal: true

module SeoGeo
  # GET /og/:key.png — Open Graph image for a page key. Link-preview bots hit this publicly, so a
  # rendering failure redirects to +og_image.fallback_url+ (briefly cached) instead of a 500.
  #
  # Only known keys render ({SeoGeo::OgImage.resolve_key}, else 404) and only constrained parameter
  # values reach the backend ({SeoGeo::OgImage.validated_params}, else 400), so a crawler cannot mint
  # unbounded cache entries or Chrome launches. When every render slot is busy the request gets the
  # fallback redirect, or a 503 with +Retry-After+, instead of waiting.
  class OgImagesController < ActionController::API
    FALLBACK_MAX_AGE = 300
    BUSY_RETRY_AFTER = 5

    def show
      config = SeoGeo.config
      key = params[:key].to_s
      return head(:not_found) unless SeoGeo::OgImage::KEY_FORMAT.match?(key)

      error = request.env[SeoGeo::OgImage::RouteConstraint::ERROR_KEY]
      raise error if error # key_resolver failed during routing: same fallback as a render failure

      resolved = request.env[SeoGeo::OgImage::RouteConstraint::ENV_KEY] || SeoGeo::OgImage.resolve_key(key, config)
      return head(:not_found) unless resolved

      og_params = SeoGeo::OgImage.validated_params(request.query_parameters, config)
      return head(:bad_request) if og_params.nil?

      page = find_page(key, config) || (resolved if resolved.is_a?(SeoGeo::Page))
      png = SeoGeo::OgImage.render(key, page: page, params: og_params, config: config)
      expires_in config.cache_control_seconds, public: true
      send_data png, type: "image/png", disposition: "inline"
    rescue SeoGeo::OgImage::Busy
      busy(config || SeoGeo.config)
    rescue StandardError => e
      fallback(e, config || SeoGeo.config)
    end

    private

    def find_page(key, config)
      locale = params[:locale].to_s
      locale = nil unless config.locales.map(&:to_s).include?(locale)
      SeoGeo.page(key, locale: locale)
    rescue KeyError
      nil
    end

    def busy(config)
      response.headers["Retry-After"] = BUSY_RETRY_AFTER.to_s
      response.headers["Cache-Control"] = "no-store"
      url = config.og_image.fallback_url
      return head(:service_unavailable) if url.nil?

      redirect_to url, allow_other_host: true, status: :found
    end

    def fallback(error, config)
      logger&.error("[seo_geo] OG image #{params[:key].inspect} failed: #{error.class}: #{error.message}")
      url = config.og_image.fallback_url
      return head(:not_found) if url.nil?

      expires_in FALLBACK_MAX_AGE, public: true
      redirect_to url, allow_other_host: true, status: :found
    end
  end
end
