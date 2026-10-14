# frozen_string_literal: true

module SeoGeo
  # GET /robots.txt — per request host. ActionController::API so +allow_browser+ and auth filters in the
  # host app's ApplicationController never answer a crawler with 406 or a login redirect.
  class RobotsController < ActionController::API
    # @return [void]
    def show
      SeoGeo::UndeclaredHost.warn_once(request.host)
      expires_in SeoGeo.config.cache_control_seconds, public: true
      render plain: SeoGeo::Robots.new(SeoGeo.config, request.host).to_s, content_type: "text/plain; charset=utf-8"
    end
  end
end
