# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "rbconfig"

# Round 5: `rake seo_geo:audit` in development, where config.hosts = [".localhost"] blocks the production hosts.
class AuditDevHostsTest < Minitest::Test
  GEM_ROOT = File.expand_path("../..", __dir__)

  def run_app(env, *args)
    Dir.mktmpdir("seo_geo_dev_hosts") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw { mount SeoGeo::Engine, at: \"/\" }\n")
      Open3.capture3({ "RAILS_ENV" => "development", "SEO_GEO_AUDIT" => nil }.merge(env), RbConfig.ruby,
                     "-I#{GEM_ROOT}/lib", "-I#{GEM_ROOT}/test", "#{GEM_ROOT}/test/support/audit_with_dev_hosts.rb",
                     root, *args, chdir: root)
    end
  end

  def test_rake_task_flag_lets_the_audit_through_config_hosts
    out, err, status = run_app({}, "rake")
    assert status.success?, err
    assert_includes out, "HOST_AUTH_FINDINGS=0"
    assert_includes out, "CANONICAL_STATUS=200"
    assert_includes err, "seo_geo audit: temporarily allowing www.example.com, example.com in config.hosts"
  end

  def test_runner_with_the_env_flag_works_too
    out, err, status = run_app({ "SEO_GEO_AUDIT" => "1" })
    assert status.success?, err
    assert_includes out, "HOST_AUTH_FINDINGS=0"
    assert_includes out, "CANONICAL_STATUS=200"
  end

  def test_without_the_flag_config_hosts_still_blocks
    out, err, status = run_app({})
    assert status.success?, err
    refute_includes out, "HOST_AUTH_FINDINGS=0"
    assert_includes out, "CANONICAL_STATUS=403"
    refute_includes err, "temporarily allowing"
  end

  def test_never_in_production
    out, err, status = run_app({ "RAILS_ENV" => "production", "SEO_GEO_AUDIT" => "1" })
    assert status.success?, err
    assert_includes out, "CANONICAL_STATUS=403"
    refute_includes out, "HOST_AUTH_FINDINGS=0"
    refute_includes err, "temporarily allowing"
  end
end
