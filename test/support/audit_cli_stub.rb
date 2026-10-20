# frozen_string_literal: true

# Subprocess fixture: substitute only Net::HTTP, leaving the real rake entrypoint and checks intact.
require "net/http"
require_relative "audit_http_stub"

AUDIT_CLI_SERVER = AuditHttpStub.new do |path, _headers, origin|
  case path
  when "/robots.txt" then [200, {}, "User-agent: *\nAllow: /\n"]
  when "/sitemap.xml"
    [200, {}, %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>#{origin}/</loc></url></urlset>)]
  when "/llms.txt" then [200, {}, "# Example"]
  when "/"
    [200, { "Content-Type" => "text/html" }, %(<html lang="en"><head><title>Example</title><meta name="description" content="A complete description of this public page, long enough to satisfy the audit checks."><link rel="canonical" href="#{origin}/"></head><body>Example</body></html>)]
  else
    [ENV["AUDIT_STUB_SOFT_404"] == "1" ? 200 : 404, {}, "Missing"]
  end
end
Net::HTTP.define_singleton_method(:new) { |host, port, proxy| AUDIT_CLI_SERVER.connection(host, port, proxy) }
