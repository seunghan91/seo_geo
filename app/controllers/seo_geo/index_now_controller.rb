# frozen_string_literal: true

module SeoGeo
  # Serves the IndexNow key file at +/<key>.txt+. The route only matches the configured key, so any
  # other +.txt+ path falls through to the application ({SeoGeo::IndexNow::KeyConstraint}).
  class IndexNowController < ActionController::API
    # GET /<key>.txt
    def key
      expires_in SeoGeo.config.cache_control_seconds, public: true
      render plain: SeoGeo.config.indexnow.key, content_type: "text/plain"
    end
  end
end
