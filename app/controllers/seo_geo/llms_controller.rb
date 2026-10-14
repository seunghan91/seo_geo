# frozen_string_literal: true

module SeoGeo
  # GET /llms.txt and /llms-full.txt — per request host; 404 where the host has no sitemap.
  class LlmsController < ActionController::API
    # @return [void]
    def show
      respond_with_text(builder.to_s)
    end

    # @return [void]
    def full
      respond_with_text(builder.full)
    end

    private

    def builder
      SeoGeo::LlmsTxt.new(SeoGeo.config, request.host)
    end

    def respond_with_text(text)
      return head(:not_found) if text.nil?

      expires_in SeoGeo.config.cache_control_seconds, public: true
      render plain: text, content_type: "text/plain; charset=utf-8"
    end
  end
end
