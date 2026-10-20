# frozen_string_literal: true

require "rack"
require "rack/mock"
require "uri"

module SeoGeo
  module Audit
    # The audit's original in-process Rack transport.
    class RackFetcher
      # @param app [#call] Rack application
      # @param config [Configuration] origins for the audited hosts
      def initialize(app:, config: SeoGeo.config)
        @app = app
        @config = config
      end

      # @return [Rack::MockResponse] original response, without following redirects
      def fetch(host, path, headers = {})
        origin = URI.parse(@config.origin_for(host))
        scheme = origin.scheme || "https"
        # Rails HostAuthorization (config.hosts) reads the Host header, not SERVER_NAME: send both, with the port
        # only when it is not the scheme's default.
        authority = origin.port && origin.port != origin.default_port ? "#{host}:#{origin.port}" : host
        env = Rack::MockRequest.env_for("#{scheme}://#{authority}#{path}",
                                        { "REMOTE_ADDR" => "127.0.0.1", "HTTP_ACCEPT" => "text/html" }.merge(headers))
        env["HTTP_HOST"] = authority
        env["HTTPS"] = "on" if scheme == "https"
        status, response_headers, body = @app.call(env)
        Rack::MockResponse.new(status, response_headers, body)
      end
    end
  end
end
