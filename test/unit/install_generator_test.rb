# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/seo_geo/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests SeoGeo::Generators::InstallGenerator
  destination File.expand_path("../tmp/install_generator", __dir__)

  ROUTES = "Rails.application.routes.draw do\n  root \"pages#home\"\nend\n"

  setup do
    prepare_destination
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), ROUTES)
  end

  teardown { FileUtils.rm_rf(destination_root) }

  def test_creates_initializer_page_copy_and_mount
    output = run_generator %w[https://www.acme.test/ --site-name=Acme]

    assert_file "config/initializers/seo_geo.rb" do |content|
      assert_includes content, 'seo.canonical_origin = "https://www.acme.test"'
      assert_includes content, 'seo.site.name = "Acme"'
      assert_includes content, 'add "/", priority: 1.0'
      # The initializer must be valid Ruby that configures a valid setup.
      SeoGeo.reset!
      eval(content, TOPLEVEL_BINDING, "seo_geo.rb") # rubocop:disable Security/Eval
      assert_empty SeoGeo.config.errors
      assert_equal 1, SeoGeo.sitemap.entries.size
    ensure
      SeoGeo.reset!
    end
    assert_file "config/seo_geo/pages/home.yml" do |content|
      data = YAML.safe_load(content)
      page = SeoGeo::Page.from_hash(:home, data["en"], locale: :en)
      assert_equal "Acme", page.title
      assert_equal 1, page.faq.size
      assert_equal "What is Acme?", page.faq.first[:question]
    end
    assert_file "config/routes.rb", /mount SeoGeo::Engine, at: "\/"/
    assert_includes output, "<%= seo_geo_head %>"
    assert_includes output, "seo_geo_html_lang"
    assert_includes output, "seo_geo_fallback_body(:home)"
  end

  def test_site_names_with_yaml_syntax_stay_valid
    run_generator ["https://www.acme.test", "--site-name=Acme: Tools #1"]
    assert_file "config/seo_geo/pages/home.yml" do |content|
      data = YAML.safe_load(content)
      assert_equal "Acme: Tools #1", data["en"]["title"]
      assert_equal "What is Acme: Tools #1?", data["en"]["faq"].first["question"]
    end
  end

  def test_mount_is_not_duplicated
    run_generator %w[https://www.acme.test]
    run_generator %w[https://www.acme.test --force]
    assert_equal 1, File.read(File.join(destination_root, "config/routes.rb")).scan("SeoGeo::Engine").size
  end

  # the mount goes after the app's routes, before a catch-all, with a note why.
  def test_mount_goes_last_and_before_a_catch_all
    File.write(File.join(destination_root, "config/routes.rb"),
               "Rails.application.routes.draw do\n  get \"/og/:username.png\", to: \"users#og\"\n" \
               "  get \"*path\", to: \"pages#spa\"\nend\n")
    output = run_generator %w[https://www.acme.test]
    lines = File.readlines(File.join(destination_root, "config/routes.rb"), chomp: true)
    og, mount, catch_all = ["/og/:username.png", "SeoGeo::Engine", "*path"].map { |text| lines.index { |line| line.include?(text) } }
    assert_operator og, :<, mount
    assert_operator mount, :<, catch_all
    assert_match(/note\s+mounted SeoGeo::Engine after your routes \(before the catch-all\)/, output)

    File.write(File.join(destination_root, "config/routes.rb"), ROUTES)
    run_generator %w[https://www.acme.test --force]
    assert_equal "Rails.application.routes.draw do\n  root \"pages#home\"\n  mount SeoGeo::Engine, at: \"/\"\nend\n",
                 File.read(File.join(destination_root, "config/routes.rb"))
  end

  # Thor's substitution mounted the engine inside a namespace and once per catch-all.
  def test_one_mount_directly_inside_draw_before_the_first_top_level_catch_all
    routes = <<~RUBY
      Rails.application.routes.draw do
        namespace :admin do
          get "*path", to: "admin#spa"
        end
        scope "/app" do
          match "*rest", to: "app#spa", via: :get
        end
        get "/og/:username.png", to: "users#og"
        get "*path", to: "pages#spa"
        get "*other", to: "pages#other"
      end
    RUBY
    File.write(File.join(destination_root, "config/routes.rb"), routes)
    run_generator %w[https://www.acme.test]
    2.times { run_generator %w[https://www.acme.test --force] }
    result = File.read(File.join(destination_root, "config/routes.rb"))
    assert_equal 1, result.scan("SeoGeo::Engine").size
    expected = routes.sub(%(  get "*path", to: "pages#spa"\n), %(  mount SeoGeo::Engine, at: "/"\n  get "*path", to: "pages#spa"\n))
    assert_equal expected, result

    nested = "Rails.application.routes.draw do\n  namespace :api do\n    get \"*path\", to: \"api#x\"\n  end\nend\n"
    File.write(File.join(destination_root, "config/routes.rb"), nested)
    run_generator %w[https://www.acme.test --force]
    assert_equal nested.sub("  end\nend\n", "  end\n  mount SeoGeo::Engine, at: \"/\"\nend\n"),
                 File.read(File.join(destination_root, "config/routes.rb"))
  end

  def test_warns_about_static_files_that_shadow_routes
    FileUtils.mkdir_p(File.join(destination_root, "public"))
    File.write(File.join(destination_root, "public/robots.txt"), "User-agent: *\n")
    output = run_generator %w[https://www.acme.test]
    assert_match(%r{warning\s+public/robots\.txt is served before the seo_geo route}, output)
  end

  def test_rejects_an_origin_with_a_path
    output = capture(:stderr) { run_generator %w[https://www.acme.test/app] }
    assert_match(/CANONICAL_ORIGIN must look like/, output)
    assert_no_file "config/initializers/seo_geo.rb"
  end
end
