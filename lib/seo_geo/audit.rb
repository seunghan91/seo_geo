# frozen_string_literal: true

module SeoGeo
  # +rake seo_geo:audit+: requests the app in-process for every known host and reports
  # problems that search engines and AI crawlers would hit. See {Audit::Runner}.
  module Audit
  end
end

require_relative "audit/report"
require_relative "audit/html_document"
require_relative "audit/checks"
require_relative "audit/static_scan"
require_relative "audit/rack_fetcher"
require_relative "audit/http_fetcher"
require_relative "audit/runner"
require_relative "audit/remote"
