# frozen_string_literal: true

namespace :seo_geo do
  # `rake seo_geo:audit` (requests every registered URL and reports problems).
  # Set before :environment so the engine adds the audited hosts to config.hosts outside production
  # (SeoGeo::Engine.allow_audit_hosts!). For `bin/rails runner`, export SEO_GEO_AUDIT=1 yourself.
  task :audit_flag do
    ENV["SEO_GEO_AUDIT"] = "1"
  end

  desc "Audit robots.txt, sitemap.xml, llms.txt and every sitemap page in-process " \
       "(FORMAT=json, HOSTS=a.com,b.com, MAX_PAGES=200); exits 1 when there are errors"
  task audit: %i[audit_flag environment] do
    report = SeoGeo::Audit::Runner.new(
      app: Rails.application,
      root: Rails.root,
      hosts: ENV["HOSTS"]&.split(",")&.map(&:strip)&.reject(&:empty?),
      max_pages: Integer(ENV.fetch("MAX_PAGES", "200"), 10)
    ).run
    puts ENV["FORMAT"].to_s.casecmp?("json") ? report.to_json : report.to_s
    exit(1) if report.errors?
  end
end
