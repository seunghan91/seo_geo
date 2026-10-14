# frozen_string_literal: true

module SeoGeo
  module Markdown
    # Rack middleware that makes +/<path>.md+ work for every route: it strips the suffix, maps
    # +/index.md+ to +/+ and marks the request as a Markdown request (+Accept: text/markdown+ and
    # +env["seo_geo.markdown"]+). Actions that include {SeoGeo::Markdownable} answer in Markdown;
    # every other action gets a plain 406 — whether Rails raised +UnknownFormat+ or the action
    # rendered HTML anyway — so a +.md+ URL never 500s or serves HTML.
    #
    # Appended to the middleware stack by the engine (after ActionDispatch::Static), so real
    # +public/*.md+ files still win.
    # llms.txt links pages as +/<path>.md+ and the root as +/index.md+.
    class PathSuffix
      ENV_KEY = "seo_geo.markdown"
      NOT_ACCEPTABLE = [406, { "content-type" => "text/plain; charset=utf-8", "vary" => "Accept" },
                        ["Not Acceptable: no Markdown version of this page\n"]].freeze
      private_constant :NOT_ACCEPTABLE

      def initialize(app)
        @app = app
      end

      def call(env)
        path = env["PATH_INFO"].to_s
        if SeoGeo.config.markdown.suffix_urls? && path.end_with?(".md") && %w[GET HEAD].include?(env["REQUEST_METHOD"])
          env["PATH_INFO"] = self.class.html_path(path)
          env["HTTP_ACCEPT"] = "text/markdown"
          env[ENV_KEY] = true
          return markdown_call(env)
        end
        @app.call(env)
      end

      # @param path [String] e.g. "/docs/intro.md", "/index.md", "/docs/index.md"
      # @return [String] "/docs/intro", "/", "/docs/"
      def self.html_path(path)
        stripped = path.delete_suffix(".md")
        return stripped.delete_suffix("index") if stripped.end_with?("/index")

        stripped.empty? ? "/" : stripped
      end

      private

      def markdown_call(env)
        status, headers, body = @app.call(env)
        return [status, headers, body] unless status.to_i == 200 && !markdown_response?(headers)

        body.close if body.respond_to?(:close)
        not_acceptable
      rescue ActionController::UnknownFormat
        not_acceptable
      rescue ActionView::MissingTemplate => e
        # An explicit +render :show+ in a non-markdownable action looks up an +.md+ template.
        raise unless e.message.match?(/formats.{0,4}\[:md\]/)

        not_acceptable
      end

      def markdown_response?(headers)
        type = headers.find { |name, _| name.to_s.casecmp?("content-type") }&.last
        type.to_s.start_with?("text/markdown")
      end

      def not_acceptable
        status, headers, body = NOT_ACCEPTABLE
        [status, headers.dup, body.dup]
      end
    end
  end
end
