# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "rbconfig"

# after_initialize validation must not stop `rails g seo_geo:install` on an app that has no
# initializer yet, must only warn in development, and must still raise in production.
class BootWithoutInitializerTest < Minitest::Test
  GEM_ROOT = File.expand_path("../..", __dir__)

  def boot(mode, env, extra_env = {})
    Dir.mktmpdir("seo_geo_fresh") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw do\n  get \"/og/:username.png\", to: \"users#og\"\nend\n")
      out, err, status = Open3.capture3({ "RAILS_ENV" => env }.merge(extra_env), RbConfig.ruby, "-I#{GEM_ROOT}/lib", "-I#{GEM_ROOT}/test",
                                        "#{GEM_ROOT}/test/support/boot_without_initializer.rb", mode, root, chdir: root)
      routes = File.read(File.join(root, "config/routes.rb"))
      yield out, err, status, routes
    end
  end

  def test_generator_runs_on_an_app_without_initializer
    boot("generate", "development") do |out, err, status, routes|
      assert status.success?, err
      assert_includes out, "BOOTED"
      assert_includes out, "GENERATED", err
      assert_operator routes.index("/og/:username.png"), :<, routes.index("SeoGeo::Engine"), "mount goes after app routes"
    end
  end

  def test_development_boot_warns_instead_of_raising
    boot("boot", "development") do |out, err, status, _|
      assert status.success?, err
      assert_includes out, "BOOTED"
      assert_includes err, "canonical_origin is not set"
    end
  end

  # having rails/generators loaded is not running a generator; boot still validates.
  def test_loaded_generators_do_not_skip_validation
    boot("generators_loaded", "development") do |out, err, status, _|
      assert status.success?, err
      assert_includes out, "BOOTED"
      assert_includes err, "canonical_origin is not set"
    end
    boot("generators_loaded", "development", "SEO_GEO_BAD_TITLE" => "1") do |out, err, status, _|
      refute status.success?
      refute_includes out, "BOOTED"
      assert_includes err, "title_template must contain %{title}"
    end
  end

  # A production rake task (assets:precompile, db:migrate in a Docker build) must not die on configuration that only
  # exists at runtime; the server boot still raises (next test).
  def test_production_rake_task_warns_instead_of_raising
    boot("rake", "production") do |out, err, status, _|
      assert status.success?, err
      assert_includes out, "BOOTED"
      assert_includes err, "seo_geo: invalid configuration ignored while a generator or rake task runs in production"
      assert_includes err, "canonical_origin is required"
    end
  end

  def test_production_boot_still_raises
    boot("boot", "production") do |out, err, status, _|
      refute status.success?
      refute_includes out, "BOOTED"
      assert_includes err, "canonical_origin is required"
    end
  end
end
