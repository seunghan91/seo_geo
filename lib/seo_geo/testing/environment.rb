# frozen_string_literal: true

module SeoGeo
  module Testing
    # Runs the block as if the app were in another environment ({Configuration#environment}), then restores it,
    # so a test can see production robots.txt, indexable heads and sitemaps. Shared by the Minitest assertions
    # ({Assertions#with_seo_geo_environment}) and the RSpec helpers.
    #
    # @example
    #   SeoGeo::Testing.with_environment("production") { get "/robots.txt" }
    # @param name [String, Symbol]
    # @param config [Configuration]
    # @return [Object] the block's value
    def self.with_environment(name, config: SeoGeo.config)
      saved = config.environment
      config.environment = name.to_s
      yield
    ensure
      config.environment = saved
    end

    # Instance helper mixed into Minitest tests and RSpec examples.
    module EnvironmentHelper
      # @param name [String, Symbol]
      # @return [Object] the block's value
      def with_seo_geo_environment(name, &block)
        Testing.with_environment(name, &block)
      end
    end
  end
end
