# frozen_string_literal: true

require "erb"

module SeoGeo
  module OgImage
    # Built-in backend: renders an ERB template to HTML and screenshots it with headless Chrome via
    # the optional ferrum gem. Add +gem "ferrum"+ and a Chrome/Chromium binary to use it.
    #
    # Template locals: +key+, +page+ (or nil), +params+, +site+ (SiteOptions), +width+, +height+.
    # Everything interpolated must go through +h(...)+ — the template is HTML.
    class FerrumBackend
      DEFAULT_TEMPLATE = File.expand_path("card.html.erb", __dir__)

      # @param config [Configuration]
      # @param browser_options [Hash] extra options for +Ferrum::Browser.new+
      def initialize(config: SeoGeo.config, browser_options: {})
        @config = config
        @browser_options = browser_options
      end

      # @return [String] PNG bytes
      def call(key, page, params)
        require "ferrum"
        width = @config.og_image.width
        height = @config.og_image.height
        browser = Ferrum::Browser.new({ headless: true, window_size: [width, height], timeout: 15 }
                                        .merge(@browser_options))
        begin
          # window_size includes browser chrome; the viewport must be exactly width x height.
          browser.resize(width: width, height: height)
          browser.go_to("about:blank")
          browser.main_frame.content = html(key, page, params)
          wait_for_assets(browser)
          browser.screenshot(format: "png", encoding: :binary)
        ensure
          browser.quit
        end
      end

      # Web fonts and images referenced by the template; a slow asset must not fail the card.
      def wait_for_assets(browser)
        browser.network.wait_for_idle(timeout: 5)
      rescue Ferrum::TimeoutError
        nil
      end

      # @return [String] the rendered HTML card
      def html(key, page, params)
        Template.new(File.read(@config.og_image.template || DEFAULT_TEMPLATE)).render(
          key: key, page: page, params: params, site: @config.site,
          width: @config.og_image.width, height: @config.og_image.height
        )
      end

      # Minimal ERB context exposing locals and +h+.
      class Template
        include ERB::Util

        def initialize(source)
          @erb = ERB.new(source, trim_mode: "-")
        end

        def render(locals)
          context = binding
          locals.each { |name, value| context.local_variable_set(name, value) }
          @erb.result(context)
        end
      end
    end
  end
end
