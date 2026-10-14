# frozen_string_literal: true

module SeoGeo
  # Delivers one IndexNow batch. Enqueued by {SeoGeo::IndexNow.submit}.
  #
  # 429, 5xx and network errors retry with polynomial backoff (5 attempts); 400/403/422 are logged
  # and discarded because the same request would fail again.
  class IndexNowJob < ActiveJob::Base
    queue_as :default

    retry_on SeoGeo::IndexNow::RetryableError, wait: :polynomially_longer, attempts: 5
    discard_on SeoGeo::IndexNow::RejectedError

    # @param host [String]
    # @param urls [Array<String>]
    # @return [SeoGeo::IndexNow::Result]
    def perform(host, urls)
      SeoGeo::IndexNow.deliver(host, urls)
    end
  end
end
