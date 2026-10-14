# frozen_string_literal: true

# Boots a development-like app whose config.hosts only allows ".localhost" (a typical development setup) and runs the audit
# in-process, in its own process:
#   ruby -Ilib -Itest test/support/audit_with_dev_hosts.rb ROOT [rake]
# "rake" goes through the real `seo_geo:audit_flag` task (which sets SEO_GEO_AUDIT=1) before booting.
# Prints "HOST_AUTH_FINDINGS=<n>" and "CANONICAL_STATUS=<status>" (a direct request with Host: www.example.com).
root, via = ARGV
if via == "rake"
  require "rake"
  load File.expand_path("../../lib/tasks/seo_geo.rake", __dir__)
  Rake::Task["seo_geo:audit_flag"].invoke
end
require "support/dummy_base"

class DevHostsApp < Rails::Application; end
SeoGeoDummyBase.apply(DevHostsApp, root: root)
DevHostsApp.config.hosts = [".localhost"]
DevHostsApp.config.logger = Logger.new($stderr)
SeoGeo.configure { |seo| SeoGeoDummyBase.configure_seo_geo(seo) }
Rails.application.initialize!

report = SeoGeo::Audit::Runner.new(app: Rails.application, hosts: ["www.example.com"], max_pages: 1).run
puts "HOST_AUTH_FINDINGS=#{report.findings.count { |item| item.check == "host_authorization" }}"
warn report.to_s
env = Rack::MockRequest.env_for("http://www.example.com/robots.txt", "HTTP_HOST" => "www.example.com")
puts "CANONICAL_STATUS=#{Rails.application.call(env).first}"
