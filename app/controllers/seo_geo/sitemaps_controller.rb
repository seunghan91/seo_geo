# frozen_string_literal: true

module SeoGeo
  # GET /sitemap.xml and /sitemap-:page.xml — per request host; 404 when the host has nothing to index.
  class SitemapsController < ActionController::API
    # @return [void]
    def show
      page = params[:page]&.to_i
      xml = SeoGeo::Sitemap::Xml.new(SeoGeo.config, SeoGeo.sitemap, request.host).render(page)
      return head(:not_found) if xml.nil?

      expires_in SeoGeo.config.cache_control_seconds, public: true
      render body: xml, content_type: "application/xml; charset=utf-8"
    end
  end
end
