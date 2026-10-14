# frozen_string_literal: true

require "rails/generators"

module SeoGeo
  module Generators
    # +bin/rails g seo_geo:install [CANONICAL_ORIGIN]+: initializer, sample page copy, engine
    # mount, layout instructions, and a warning for static files that would shadow the engine routes.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      SHADOWED_FILES = %w[robots.txt sitemap.xml llms.txt llms-full.txt].freeze
      MOUNT = 'mount SeoGeo::Engine, at: "/"'
      # A catch-all route (+get "*path"+, +match "/*slug"+, ...).
      CATCH_ALL = /\A[ \t]*(?:get|match|any|post)\b[ \t(]*["']\/?\*/
      DRAW = /\.routes\.draw\s+do\b/
      # Lines that open a block closed by +end+: a trailing +do+ (optionally +do |args|+) or a leading keyword.
      OPENS_BLOCK = /(?:\bdo(?:\s*\|[^|]*\|)?\s*(?:#.*)?\z)|\A\s*(?:if|unless|case|begin|while|until|def|class|module)\b/
      CLOSES_BLOCK = /\A\s*end\b/

      # @param lines [Array<String>] config/routes.rb
      # @return [Integer, nil] line index for the mount: directly inside +routes.draw+ (never inside a scope or
      #   namespace), before its first top-level catch-all, else before the +end+ closing the draw block
      def self.mount_index(lines)
        start = lines.index { |line| line.match?(DRAW) }
        return nil if start.nil?

        depth = 1
        lines.each_with_index.drop(start + 1).each do |line, index|
          return index if depth == 1 && line.match?(CATCH_ALL)

          if line.match?(CLOSES_BLOCK)
            depth -= 1
            return index if depth.zero?
          elsif line.match?(OPENS_BLOCK)
            depth += 1
          end
        end
        nil
      end

      argument :canonical_origin, type: :string, default: "https://www.example.com",
                                  banner: "https://www.example.com"

      class_option :site_name, type: :string, default: nil, desc: "site.name (defaults to the application name)"

      def validate_origin
        return if canonical_origin.match?(%r{\Ahttps?://[^/\s]+/?\z})

        raise Thor::Error, "CANONICAL_ORIGIN must look like https://www.example.com (got #{canonical_origin.inspect})"
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/seo_geo.rb"
      end

      def create_home_page
        template "home.yml.tt", "config/seo_geo/pages/home.yml"
      end

      # The mount goes last (before a top-level catch-all +get "*path"+ if there is one), not at the top where Rails'
      # +route+ puts it: routes match in order, so the app's own routes (e.g. +/og/:username.png+) stay first. One
      # insertion point, directly inside +routes.draw+; an existing mount is left alone.
      def mount_engine
        routes = File.join(destination_root, "config/routes.rb")
        return route(MOUNT) unless File.exist?(routes)

        content = File.read(routes)
        if content.include?("SeoGeo::Engine")
          say_status :identical, "config/routes.rb (SeoGeo::Engine already mounted)", :blue
          return
        end

        lines = content.lines
        index = self.class.mount_index(lines.map(&:chomp))
        return route(MOUNT) if index.nil?

        catch_all = lines[index].match?(CATCH_ALL)
        indent = lines[index][/\A[ \t]*/]
        indent = "#{indent}  " unless catch_all
        lines.insert(index, "#{indent}#{MOUNT}\n")
        say_status :insert, "config/routes.rb", :green
        File.write(routes, lines.join) unless options[:pretend]
        say_status :note, "mounted SeoGeo::Engine after your routes#{catch_all ? " (before the catch-all)" : ""}: " \
                          "app routes win where paths overlap, and /robots.txt, /sitemap.xml, /llms.txt still reach " \
                          "the engine. Keep any catch-all route below the mount.", :blue
      end

      def warn_about_static_files
        SHADOWED_FILES.each do |name|
          next unless File.exist?(File.join(destination_root, "public", name))

          say_status :warning, "public/#{name} is served before the seo_geo route — delete it " \
                               "(rake seo_geo:audit reports it as an error)", :yellow
        end
      end

      def show_layout_instructions
        say <<~TEXT

          seo_geo is installed. In app/views/layouts/application.html.erb:

            <html lang="<%= seo_geo_html_lang %>">
              <head>
                <%= seo_geo_head %>          <!-- replaces your <title>, meta description, canonical, JSON-LD -->
              </head>

          Remove any other <title> tag (seo_geo_head emits exactly one).

          Client-rendered pages (Inertia/React/Vue): render the copy for crawlers that do not run JavaScript
          inside <body>, and call window.SeoGeo.mounted() once the app has mounted:

            <%= seo_geo_fallback_body(:home) %>

          In controllers: seo title: "...", description: "..." or seo_geo_page(:home).
          Then run: bin/rails seo_geo:audit
        TEXT
      end

      private

      def origin
        canonical_origin.chomp("/")
      end

      def site_name
        options[:site_name] || default_site_name
      end

      def default_site_name
        name = defined?(::Rails.application) && ::Rails.application ? ::Rails.application.class.module_parent_name : nil
        name ? name.underscore.humanize : "My site"
      rescue StandardError
        "My site"
      end
    end
  end
end
