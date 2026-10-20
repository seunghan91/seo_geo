# frozen_string_literal: true

require "net/http"
require "uri"
require "thread"
require "rack/mock"

module SeoGeo
  module Audit
    # Serial HTTP transport. The initial response is preserved; redirect targets are separate probes.
    class HttpFetcher
      REDIRECTS = [301, 302, 303, 307, 308].freeze
      MAX_HOPS = 5
      # @return [Array<Hash>] initial response and each explicitly requested redirect target
      attr_reader :chain
      # @return [String, nil] why the redirect trace could not finish
      attr_reader :redirect_error

      # @param origin [String] HTTP(S) origin to request
      # @param delay [Numeric] minimum pause between requests, including redirect probes
      # @param timeout [Numeric] connect/read/write timeout in seconds
      def initialize(origin:, delay: 0.5, timeout: 10)
        @origin = self.class.http_uri(origin).to_s
        raise ArgumentError, "delay must be nonnegative and timeout positive" unless delay >= 0 && timeout > 0

        @delay = delay
        @timeout = timeout
        @mutex = Mutex.new
        @chain = []
      end

      # Validates caller URLs and redirect locations before opening a connection.
      # @return [URI::HTTP]
      def self.http_uri(url)
        uri = URI.parse(url.to_s)
        unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo
          raise ArgumentError, "audit URL must be HTTP(S), with a host and without credentials"
        end
        uri.path = "/" if uri.path.empty?
        uri.fragment = nil
        uri
      end

      # @return [Rack::MockResponse] first response (never replaced by a redirect target)
      def fetch(_host, path, headers = {})
        @mutex.synchronize do
          @chain = []
          @redirect_error = nil
          uri = self.class.http_uri(URI.join(@origin, path).to_s)
          first = nil
          loop do
            response = request(uri, headers)
            first ||= response
            @chain << { url: uri.to_s, status: response.status, headers: response.headers }
            break unless REDIRECTS.include?(response.status) && response.headers["location"]
            if @chain.size > MAX_HOPS
              @redirect_error = "redirect chain exceeds #{MAX_HOPS} hops"
              break
            end
            target = self.class.http_uri(URI.join(uri.to_s, response.headers["location"]).to_s)
            if @chain.any? { |hop| hop[:url] == target.to_s }
              @redirect_error = "redirect loop to #{target}"
              break
            end
            uri = target
          end
          first
        rescue StandardError => e
          raise unless first

          @redirect_error = "#{e.class}: #{e.message.lines.first.to_s.strip}"
          first
        end
      end

      private

      def request(uri, headers)
        if @last_request
          remaining = @delay - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_request)
          sleep(remaining) if remaining.positive?
        end
        request = Net::HTTP::Get.new(uri.request_uri)
        request["Accept"] = "text/html"
        headers.each { |name, value| request[name.delete_prefix("HTTP_").tr("_", "-")] = value }
        request["User-Agent"] = "seo_geo-audit/#{SeoGeo::VERSION}"
        # Ignore ambient proxy credentials/configuration; audit the requested origin directly.
        http = Net::HTTP.new(uri.hostname, uri.port, nil)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = http.read_timeout = http.write_timeout = @timeout
        http.max_retries = 0
        response = http.start { |connection| connection.request(request) }
        Rack::MockResponse.new(response.code.to_i, response.to_hash.transform_values { |values| values.join("\n") }, response.body.to_s)
      ensure
        @last_request = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
