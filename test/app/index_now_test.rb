# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class IndexNowAppTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  KEY = "a1b2c3d4e5f6-key"

  def setup
    @indexnow = SeoGeo.config.indexnow
    @saved = { key: @indexnow.key, enabled: @indexnow.enabled, dry_run: @indexnow.dry_run }
    ActiveJob::Base.queue_adapter = :test
  end

  def teardown
    @saved.each { |name, value| @indexnow.public_send("#{name}=", value) }
  end

  def test_key_file_is_served_when_configured
    @indexnow.key = KEY
    get "/#{KEY}.txt"
    assert_response :success
    assert_equal KEY, response.body
    assert_equal "text/plain", response.media_type
    assert_equal "max-age=3600, public", response.headers["Cache-Control"]
  end

  def test_key_file_is_404_when_unset
    @indexnow.key = nil
    assert_equal 404, status_of("/#{KEY}.txt")
  end

  def test_other_txt_paths_fall_through
    @indexnow.key = KEY
    assert_equal 404, status_of("/someother-file.txt")
  end

  def test_llms_and_robots_txt_are_not_caught
    @indexnow.key = KEY
    assert_equal "seo_geo/index_now", engine_controller_for("/#{KEY}.txt")
    %w[/llms-full.txt /llms.txt /robots.txt].each do |path|
      refute_equal "seo_geo/index_now", engine_controller_for(path), path
    end
    @indexnow.key = "llms-full"
    assert_equal 404, status_of("/llms-full.txt")
    assert_includes SeoGeo.config.errors.join, "collides"
  end

  def test_invalid_key_is_not_served
    @indexnow.key = "short"
    assert_equal 404, status_of("/short.txt")
  end

  def test_submit_enqueues_one_job_per_host_batch
    @indexnow.enabled = true
    @indexnow.key = KEY
    assert_enqueued_jobs 1, only: SeoGeo::IndexNowJob do
      SeoGeo::IndexNow.submit(["/a", "/a", "https://example.com/b"])
    end
    job = enqueued_jobs.last
    assert_equal ["www.example.com", ["https://www.example.com/a", "https://www.example.com/b"]], job[:args]
  end

  def test_job_dry_run_delivers_without_network
    @indexnow.enabled = true
    @indexnow.key = KEY
    @indexnow.dry_run = true
    result = perform_enqueued_jobs { SeoGeo::IndexNowJob.perform_now("www.example.com", ["https://www.example.com/a"]) }
    assert_predicate result, :dry_run
  end

  def test_job_discards_rejected_and_retries_retryable
    handlers = SeoGeo::IndexNowJob.rescue_handlers.map(&:first)
    assert_includes handlers, "SeoGeo::IndexNow::RetryableError"
    assert_includes handlers, "SeoGeo::IndexNow::RejectedError"
  end

  private

  def engine_controller_for(path)
    SeoGeo::Engine.routes.recognize_path(path)[:controller]
  rescue ActionController::RoutingError
    nil
  end

  def status_of(path)
    get path
    response.status
  rescue ActionController::RoutingError
    404
  end
end
