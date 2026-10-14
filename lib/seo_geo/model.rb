# frozen_string_literal: true

module SeoGeo
  # Model macro that submits a record's public URL to IndexNow after commit.
  # The engine extends ActiveRecord::Base with it; other ORMs can +extend SeoGeo::Model+ as long as
  # they provide +after_commit+.
  #
  # @example
  #   class Article < ApplicationRecord
  #     seo_geo_indexnow on: :publish, url: ->(article) { Rails.application.routes.url_helpers.article_url(article) }
  #   end
  module Model
    EVENTS = %i[create update destroy publish].freeze

    # @param on [Symbol, Array<Symbol>] +:create+, +:update+, +:destroy+ and/or +:publish+.
    #   +:publish+ submits after create or update while the record is published (see +published+) and
    #   after the update that unpublishes it, so search engines also learn about removals.
    # @param url [Symbol, #call] method name or +(record) -> String | Array<String>+ (paths are folded onto
    #   the canonical origin)
    # @param published [Symbol, #call] predicate for +:publish+ (default +:published?+)
    # @param if [Symbol, #call, nil] extra condition
    # @return [void]
    def seo_geo_indexnow(on: %i[create update destroy], url:, published: :published?, if: nil)
      events = Array(on).map(&:to_sym)
      unknown = events - EVENTS
      raise ConfigurationError, "seo_geo_indexnow on: unknown event(s) #{unknown.inspect}" unless unknown.empty?
      raise ConfigurationError, "seo_geo_indexnow needs url: (a method name or a callable)" if url.nil?

      condition = binding.local_variable_get(:if)
      commit_on = events.flat_map { |event| event == :publish ? %i[create update] : [event] }.uniq

      after_commit(on: commit_on) do
        Model.submit_for(self, events: events, url: url, published: published, condition: condition)
      end
    end

    class << self
      # @api private
      def submit_for(record, events:, url:, published:, condition:)
        return unless call_option(record, condition, default: true)
        return unless publish_relevant?(record, events, published)

        urls = call_option(record, url, default: nil)
        SeoGeo::IndexNow.submit(urls) if urls
      rescue StandardError => e
        # A failed notification must never break the transaction's callbacks chain.
        SeoGeo::IndexNow.logger.error("[seo_geo] IndexNow submit failed for #{record.class}: #{e.class}: #{e.message}")
        nil
      end

      private

      # Explicit :create/:update/:destroy events always submit. :publish alone submits only while
      # published, or right after the update that unpublished the record.
      def publish_relevant?(record, events, published)
        return true unless events.include?(:publish)
        return true if (events & %i[create update destroy]).any? { |event| fired?(record, event) }
        return true if call_option(record, published, default: true)

        was_published?(record, published)
      end

      def fired?(record, event)
        case event
        when :create then record.respond_to?(:previously_new_record?) && record.previously_new_record?
        when :destroy then record.respond_to?(:destroyed?) && record.destroyed?
        when :update
          !(record.respond_to?(:previously_new_record?) && record.previously_new_record?) &&
            !(record.respond_to?(:destroyed?) && record.destroyed?)
        end
      end

      # For +published: :published?+ backed by a +published+/+published_at+/+status+ column, the
      # saved change tells whether the record was published before this commit.
      def was_published?(record, published)
        return false unless published.is_a?(Symbol) && record.respond_to?(:saved_changes)

        column = published.to_s.delete_suffix("?")
        change = record.saved_changes[column] || record.saved_changes["#{column}_at"]
        return false unless change

        before = change.first
        before.respond_to?(:empty?) ? !before.empty? : !!before
      end

      def call_option(record, option, default:)
        case option
        when nil then default
        when Symbol, String then record.respond_to?(option) ? record.public_send(option) : default
        else option.arity.zero? ? record.instance_exec(&option) : option.call(record)
        end
      end
    end
  end
end
