# frozen_string_literal: true

require "logger"
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "active_job/railtie" # IndexNowJob
require "seo_geo"

# Settings shared by test/dummy (ERB) and test/dummy_inertia (empty #app mount point).
# Only one dummy boots per process; Rakefile runs each in its own process.
module SeoGeoDummyBase
  def self.apply(app_class, root:)
    app_class.configure do
      config.root = root
      config.load_defaults Rails::VERSION::STRING.to_f
      config.eager_load = false
      config.secret_key_base = "seo-geo-dummy-test-secret-" * 4
      config.hosts.clear
      config.logger = Logger.new(nil)
      config.active_support.deprecation = :stderr
      config.action_dispatch.show_exceptions = :none
    end
  end

  def self.configure_seo_geo(seo)
    seo.site.name = "Dummy"
    seo.site.description = "A dummy application for seo_geo tests."
    seo.site.default_locale = :en
    seo.canonical_origin = "https://www.example.com"
    seo.canonical_aliases = ["example.com"]
    seo.locales = %i[en ko]
    seo.indexable_environments = %w[production test]
  end
end
