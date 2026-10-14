# frozen_string_literal: true

require "json"
require "logger"
require "net/http"
require "openssl"
require "uri"

module SeoGeo
  # IndexNow (https://www.indexnow.org/documentation): tells Bing, Naver, Yandex, Seznam and Yep that
  # URLs changed. One POST to the shared endpoint reaches every participant. Google does not take part.
  #
  # @example
  #   SeoGeo.configure do |c|
  #     c.indexnow.enabled = true
  #     c.indexnow.key = ENV["INDEXNOW_KEY"]   # also served at /<key>.txt
  #   end
  #   SeoGeo::IndexNow.submit(["/articles/1", "https://www.example.com/articles/2"])
  #
  # Outside indexable environments (or with +indexnow.dry_run = true+) the payload is logged, not sent.
  module IndexNow
    # Base class for delivery failures.
    class Error < StandardError
      # @return [Integer, nil] HTTP status
      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end
    end

    # 429, 5xx and network errors: the job retries with backoff.
    class RetryableError < Error; end

    # 400 bad request, 403 key not valid, 422 URLs do not belong to the host: retrying cannot help.
    class RejectedError < Error; end

    # Names other routes serve as +/<name>.txt+; never accepted as a key.
    RESERVED_KEYS = %w[robots llms llms-full humans security ads app-ads].freeze

    # Route constraint for the key file: matches only while a valid, non-reserved key is configured
    # and equals the requested one, so /robots.txt, /llms-full.txt and other +.txt+ paths are never caught.
    module KeyConstraint
      # @param request [ActionDispatch::Request]
      # @return [Boolean]
      def self.matches?(request)
        key = SeoGeo.config.indexnow.key.to_s
        IndexNowOptions::KEY_FORMAT.match?(key) && !RESERVED_KEYS.include?(key.downcase) &&
          request.path_parameters[:indexnow_key] == key
      end
    end

    # Outcome of one POST (or one dry run).
    # @!attribute host [String]
    # @!attribute urls [Array<String>]
    # @!attribute status [Integer, nil] HTTP status; nil for a dry run
    # @!attribute dry_run [Boolean]
    Result = Data.define(:host, :urls, :status, :dry_run)

    REJECTED = {
      400 => "bad request (invalid payload format)",
      403 => "key not valid (key file missing or its content does not match)",
      422 => "URLs do not belong to the host, or the key does not match the protocol schema"
    }.freeze

    class << self
      # @return [Logger]
      attr_writer :logger

      # @return [Logger] Rails.logger when available
      def logger
        @logger || (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) || Logger.new($stderr)
      end

      # Normalizes, de-duplicates and groups URLs by host, then enqueues one {IndexNowJob} per batch
      # (or delivers inline when ActiveJob is not loaded).
      # @param urls [String, Array<String>] absolute URLs or paths; paths and alias hosts fold onto
      #   the canonical origin via +config.canonical_url+
      # @param config [Configuration]
      # @return [Array<Array(String, Array<String>)>] the +[host, urls]+ batches handed off; empty when disabled
      def submit(urls, config: SeoGeo.config)
        return [] unless config.indexnow.enabled

        batches(urls, config: config).each do |host, list|
          if job_class
            job_class.perform_later(host, list)
          else
            deliver(host, list, config: config)
          end
        end
      end

      # @param urls [String, Array<String>]
      # @param config [Configuration]
      # @return [Array<Array(String, Array<String>)>] +[host, urls]+ pairs of at most +batch_size+ URLs
      def batches(urls, config: SeoGeo.config)
        grouped = normalize(urls, config).group_by { |url| URI.parse(url).host }
        grouped.flat_map do |host, list|
          if config.indexable_environment? && !config.host_policy(host).indexable
            logger.info("[seo_geo] IndexNow skipped #{list.size} URL(s) on non-indexable host #{host}")
            next []
          end
          list.each_slice(config.indexnow.batch_size).map { |slice| [host, slice] }
        end
      end

      # @param host [String]
      # @param urls [Array<String>]
      # @param config [Configuration]
      # @return [Hash] the JSON body defined by the protocol
      def payload(host, urls, config: SeoGeo.config)
        key = config.indexnow.key
        { host: host, key: key, keyLocation: "#{config.origin_for(host)}/#{key}.txt", urlList: urls }
      end

      # @param config [Configuration]
      # @return [Boolean] +indexnow.dry_run+, or true outside indexable environments when it is nil
      def dry_run?(config: SeoGeo.config)
        value = config.indexnow.dry_run
        value.nil? ? !config.indexable_environment? : value
      end

      # POSTs one batch. Called by {IndexNowJob}; usable directly for synchronous delivery.
      # @param host [String]
      # @param urls [Array<String>]
      # @param config [Configuration]
      # @raise [RetryableError] on 429, 5xx or a network error
      # @raise [RejectedError] on 400, 403, 422 or another unexpected status
      # @return [Result]
      def deliver(host, urls, config: SeoGeo.config)
        body = JSON.generate(payload(host, urls, config: config))
        if dry_run?(config: config)
          logger.info("[seo_geo] IndexNow dry-run POST #{config.indexnow.endpoint} #{body}")
          return Result.new(host: host, urls: urls, status: nil, dry_run: true)
        end

        status = post(config.indexnow.endpoint, body)
        handle(status, host, urls)
      end

      private

      def job_class
        defined?(ActiveJob::Base) && defined?(SeoGeo::IndexNowJob) ? SeoGeo::IndexNowJob : nil
      end

      def normalize(urls, config)
        Array(urls).flatten.compact.map(&:to_s).reject(&:empty?).filter_map do |url|
          folded = config.canonical_url(url)
          folded if folded.start_with?("http://", "https://")
        rescue URI::InvalidURIError
          logger.warn("[seo_geo] IndexNow ignored invalid URL #{url.inspect}")
          nil
        end.uniq
      end

      def post(endpoint, body)
        uri = URI.parse(endpoint)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json; charset=utf-8"
        request.body = body
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: 5, read_timeout: 15) do |http|
          http.request(request)
        end
        response.code.to_i
      rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => e
        raise RetryableError, "IndexNow request failed: #{e.class}: #{e.message}"
      end

      def handle(status, host, urls)
        case status
        when 200, 202
          logger.info("[seo_geo] IndexNow #{status} for #{urls.size} URL(s) on #{host}")
          Result.new(host: host, urls: urls, status: status, dry_run: false)
        when 429, 500..599
          raise RetryableError.new("IndexNow #{status} for #{host} (#{status == 429 ? "too many requests" : "server error"}); will retry", status: status)
        else
          reason = REJECTED.fetch(status, "unexpected response")
          logger.error("[seo_geo] IndexNow #{status} for #{host}: #{reason}; not retrying")
          raise RejectedError.new("IndexNow #{status} for #{host}: #{reason}", status: status)
        end
      end
    end
  end
end
