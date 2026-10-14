# frozen_string_literal: true

require "active_support/concern"
require_relative "markdown/negotiation"
require_relative "markdown/document"
require_relative "markdown/path_suffix"

module SeoGeo
  # Serves a Markdown version of HTML actions to agents (+Accept: text/markdown+ or a +.md+ URL).
  #
  # The action runs and renders HTML as usual; an +after_action+ then converts the main content to
  # Markdown, prepends YAML frontmatter and appends JSON-LD in a +json+ fence. Responses of
  # markdownable actions always carry +Vary: Accept+, HTML or not, so caches keep the two apart.
  #
  # @example Every action of a controller
  #   class PagesController < ApplicationController
  #     include SeoGeo::Markdownable
  #   end
  #
  # @example Selected actions, an Inertia page backed by page copy, a custom selector
  #   class LandingController < ApplicationController
  #     include SeoGeo::Markdownable
  #     seo_geo_markdown only: :show, page: :home, selector: "#content"
  #   end
  #
  # @example .md URLs need no routes: {SeoGeo::Markdown::PathSuffix} maps /articles/1.md to /articles/1
  #   and /index.md to /, so every markdownable action answers both forms.
  module Markdownable
    extend ActiveSupport::Concern

    # Header that tells an origin-side CDN converter (or a test) the response already is Markdown.
    CONTENT_TYPE = "text/markdown; charset=utf-8"

    included do
      class_attribute :seo_geo_markdown_options, instance_writer: false, default: {}
      before_action :seo_geo_prepare_markdown, if: :seo_geo_markdownable_action?
      after_action :seo_geo_finish_markdown, if: :seo_geo_markdownable_action?
    end

    class_methods do
      # @param only [Symbol, Array<Symbol>, nil] restrict to these actions
      # @param except [Symbol, Array<Symbol>, nil] every action but these
      # @param page [Symbol, #call, nil] page key (or +(controller) -> key+) whose copy is used when the
      #   HTML has no main content, e.g. an Inertia mount point
      # @param selector [String, nil] main-content selector overriding +config.markdown.selector+
      # @return [void]
      def seo_geo_markdown(only: nil, except: nil, page: nil, selector: nil)
        self.seo_geo_markdown_options = {
          only: only && Array(only).map(&:to_s), except: except && Array(except).map(&:to_s),
          page: page, selector: selector
        }
      end
    end

    # @return [Boolean] true when Markdown is enabled and this action is covered by +seo_geo_markdown only:/except:+
    def seo_geo_markdown_available?
      SeoGeo.config.markdown.enabled && seo_geo_markdownable_action?
    end

    private

    def seo_geo_markdownable_action?
      options = seo_geo_markdown_options
      return false if options[:only] && !options[:only].include?(action_name)
      return false if options[:except]&.include?(action_name)

      true
    end

    def seo_geo_markdown_requested?
      return false unless SeoGeo.config.markdown.enabled

      request.env[SeoGeo::Markdown::PathSuffix::ENV_KEY] || params[:format].to_s == "md" ||
        SeoGeo::Markdown::Negotiation.markdown?(request.headers["Accept"])
    end

    # Render HTML whatever was asked for; the after_action converts it. When Rails picked :md from an
    # Accept header the negotiation turned down (e.g. +text/markdown;q=0+), HTML is the fallback.
    def seo_geo_prepare_markdown
      @seo_geo_markdown = seo_geo_markdown_requested?
      request.format = :html if @seo_geo_markdown || request.format&.symbol == :md
    end

    def seo_geo_finish_markdown
      seo_geo_append_vary("Accept")
      return unless @seo_geo_markdown && response.status == 200 && response.media_type.to_s == "text/html"

      document = SeoGeo::Markdown::Document.new(
        response.body, config: SeoGeo.config, url: seo_geo_html_url, page: seo_geo_markdown_page,
                       selector: seo_geo_markdown_options[:selector]
      )
      seo_geo_merge_robots_header(document.robots)
      response.body = document.to_s
      response.headers["Content-Type"] = CONTENT_TYPE
      seo_geo_content_signal_headers
    end

    # Carries the HTML's robots metas (global and crawler-specific) over to the Markdown response, merged with
    # the X-Robots-Tag already set ({SeoGeo::RobotsDirectives}): global directives stay global even when the
    # header only had scoped ones (+googlebot: noindex+ does not cover other crawlers), and nothing is dropped.
    # @param directives [SeoGeo::RobotsDirectives]
    def seo_geo_merge_robots_header(directives)
      existing = SeoGeo::RobotsDirectives.parse_header(response.headers["X-Robots-Tag"])
      merged = existing.merge(directives.restrictive)
      return if merged == existing

      response.headers["X-Robots-Tag"] = merged.to_header
    end

    def seo_geo_append_vary(value)
      current = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
      return if current.any? { |name| name.casecmp?(value) }

      response.headers["Vary"] = (current + [value]).join(", ")
    end

    def seo_geo_content_signal_headers
      config = SeoGeo.config
      return unless config.markdown.content_signal_header

      response.headers["Content-Signal"] = config.content_signal_value
      usage = config.content_usage_value
      response.headers["Content-Usage"] = usage if usage
    end

    # The HTML URL this Markdown represents (".md" removed), for the canonical fallback.
    def seo_geo_html_url
      request.url.sub(/\.md(?=\?|\z)/, "")
    end

    def seo_geo_markdown_page
      key = seo_geo_markdown_options[:page]
      key = key.call(self) if key.respond_to?(:call)
      return nil if key.nil?

      SeoGeo.page(key)
    rescue KeyError
      nil
    end
  end
end
