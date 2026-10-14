# frozen_string_literal: true

# Boots a fresh application that has no seo_geo initializer , in its own process.
#   ruby -Ilib -Itest test/support/boot_without_initializer.rb MODE ROOT
# MODE: "generate" (load the generate command before boot, like `bin/rails g`, then run seo_geo:install),
# "generators_loaded" (only require rails/generators, as gems and tests do), "rake" (a top-level rake task) or "boot".
# RAILS_ENV picks the environment; SEO_GEO_BAD_TITLE=1 adds an invalid title_template.
# Prints "BOOTED" after initialize!, "GENERATED" after the generator ran.
mode, root = ARGV
require "support/dummy_base"
if mode == "generate"
  require "rails/command"
  require "rails/commands/generate/generate_command"
end
require "rails/generators" if mode == "generators_loaded"
if mode == "rake"
  require "rake"
  Rake.application.top_level_tasks << "assets:precompile" # what `bin/rails assets:precompile` sets before boot
end
SeoGeo.config.title_template = "no placeholder" if ENV["SEO_GEO_BAD_TITLE"]

class FreshApp < Rails::Application; end
SeoGeoDummyBase.apply(FreshApp, root: root)
FreshApp.config.logger = Logger.new($stderr)
Rails.application.initialize!
puts "BOOTED"
if mode == "generate"
  Rails::Generators.invoke("seo_geo:install", ["https://www.acme.test"], behavior: :invoke, destination_root: root)
  puts "GENERATED" if File.exist?(File.join(root, "config/initializers/seo_geo.rb"))
end
