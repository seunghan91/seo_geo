# frozen_string_literal: true

require "minitest/autorun"

if (dummy = ENV["SEO_GEO_DUMMY"])
  # App tests: boot exactly one dummy application (see Rakefile test:erb / test:inertia).
  ENV["RAILS_ENV"] = "test"
  require_relative "#{dummy}/config/environment"
  require "rails/test_help"
else
  require "seo_geo"
end

module SeoGeoTestHelpers
  # @return [Boolean] true when running against test/dummy_inertia
  def inertia_dummy?
    ENV["SEO_GEO_DUMMY"] == "dummy_inertia"
  end

  def configured(**overrides)
    SeoGeo::Configuration.new.tap do |config|
      config.canonical_origin = "https://www.example.com"
      overrides.each { |name, value| config.public_send("#{name}=", value) }
      yield config if block_given?
    end
  end
end

class Minitest::Test
  include SeoGeoTestHelpers
end
