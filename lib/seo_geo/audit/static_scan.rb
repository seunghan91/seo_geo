# frozen_string_literal: true

module SeoGeo
  module Audit
    # File-system checks that need no request: static files shadowing the engine routes, and app code
    # that branches on the User-Agent header (a User-Agent is a claim, not an identity — anyone can send
    # "GPTBot"; see {SeoGeo::BotVerifier}).
    class StaticScan
      SHADOWED_FILES = %w[robots.txt sitemap.xml llms.txt llms-full.txt].freeze
      USER_AGENT_READ = /request\.user_agent|request\.headers\[\s*["']User-Agent["']\s*\]|HTTP_USER_AGENT/
      BRANCHING = /\b(?:if|unless|elsif|when|case|while|until)\b|&&|\|\||=~|\?\s|\.(?:match\??|include\?|start_with\?|end_with\?|in\?)|\?\z/
      SCANNED = %w[app/**/*.rb app/**/*.erb lib/**/*.rb lib/**/*.rake].freeze

      # @param root [String, Pathname] application root
      def initialize(root)
        @root = root.to_s
      end

      # @param report [Report]
      # @return [Report]
      def call(report)
        shadowed_files(report)
        user_agent_branches(report)
        report
      end

      private

      def shadowed_files(report)
        SHADOWED_FILES.each do |name|
          path = File.join(@root, "public", name)
          next unless File.file?(path)

          report.add(:error, "static.shadowing", "public/#{name} is served before the seo_geo route; delete it",
                     url: "public/#{name}")
        end
      end

      def user_agent_branches(report)
        SCANNED.flat_map { |pattern| Dir.glob(File.join(@root, pattern)) }.uniq.sort.each do |file|
          File.foreach(file).with_index(1) do |line, number|
            code = line.chomp.sub(/#(?!\{).*\z/, "")
            next unless code.match?(USER_AGENT_READ) && code.match?(BRANCHING)

            report.add(:warning, "code.user_agent_branch",
                       "branches on the User-Agent header; never use it for access, content or rate-limit " \
                       "decisions (it is spoofable) — use SeoGeo::BotVerifier when a bot must be trusted",
                       url: "#{relative(file)}:#{number}")
          end
        rescue ArgumentError, Errno::ENOENT
          next
        end
      end

      def relative(file)
        file.delete_prefix("#{@root}/")
      end
    end
  end
end
