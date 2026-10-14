# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "stringio"

class IndexNowTest < Minitest::Test
  KEY = "a1b2c3d4e5f6-key"

  FakeResponse = Struct.new(:code)

  # Stands in for Net::HTTP.start: records requests, answers with queued status codes.
  class FakeHttp
    attr_reader :requests, :starts

    def initialize(*codes)
      @codes = codes
      @requests = []
      @starts = []
    end

    def start(host, port, **options)
      @starts << [host, port, options]
      yield self
    end

    def request(request)
      @requests << request
      FakeResponse.new(@codes.shift.to_s)
    end
  end

  def setup
    @log = StringIO.new
    SeoGeo::IndexNow.logger = Logger.new(@log)
  end

  def teardown
    SeoGeo::IndexNow.logger = nil
  end

  def config(**indexnow)
    configured do |c|
      c.canonical_aliases = ["example.com"]
      c.host "shop.example.com"
      c.host "private.example.com", indexable: false
      c.environment = "production"
      c.indexnow.enabled = true
      c.indexnow.key = KEY
      indexnow.each { |name, value| c.indexnow.public_send("#{name}=", value) }
    end
  end

  def with_http(fake, &block)
    Net::HTTP.stub(:start, fake.method(:start), &block)
  end

  def test_payload_shape
    payload = SeoGeo::IndexNow.payload("www.example.com", ["https://www.example.com/a"], config: config)
    assert_equal({ host: "www.example.com", key: KEY, keyLocation: "https://www.example.com/#{KEY}.txt",
                   urlList: ["https://www.example.com/a"] }, payload)
  end

  def test_batches_dedupe_fold_group_and_split
    urls = ["/a", "https://example.com/a", "/b?utm=1", "https://shop.example.com/x", "https://private.example.com/p", "/c", nil, ""]
    batches = SeoGeo::IndexNow.batches(urls, config: config(batch_size: 2))
    assert_equal [
      ["www.example.com", ["https://www.example.com/a", "https://www.example.com/b"]],
      ["www.example.com", ["https://www.example.com/c"]],
      ["shop.example.com", ["https://shop.example.com/x"]]
    ], batches
    assert_includes @log.string, "skipped 1 URL(s) on non-indexable host private.example.com"
  end

  def test_full_protocol_batch_size
    urls = (1..10_001).map { |n| "/p/#{n}" }
    sizes = SeoGeo::IndexNow.batches(urls, config: config).map { |_host, list| list.size }
    assert_equal [10_000, 1], sizes
  end

  def test_submit_disabled_returns_empty
    assert_equal [], SeoGeo::IndexNow.submit(["/a"], config: config(enabled: false))
  end

  def test_dry_run_defaults_follow_environment
    assert SeoGeo::IndexNow.dry_run?(config: configured { |c| c.environment = "development" })
    refute SeoGeo::IndexNow.dry_run?(config: config)
    assert SeoGeo::IndexNow.dry_run?(config: config(dry_run: true))
  end

  def test_dry_run_logs_payload_and_sends_nothing
    fake = FakeHttp.new
    result = with_http(fake) { SeoGeo::IndexNow.deliver("www.example.com", ["https://www.example.com/a"], config: config(dry_run: true)) }
    assert result.dry_run
    assert_empty fake.requests
    assert_includes @log.string, %(IndexNow dry-run POST https://api.indexnow.org/indexnow {"host":"www.example.com")
  end

  def test_posts_json_and_accepts_200_and_202
    [200, 202].each do |code|
      fake = FakeHttp.new(code)
      result = with_http(fake) { SeoGeo::IndexNow.deliver("www.example.com", ["https://www.example.com/a"], config: config) }
      assert_equal code, result.status
      request = fake.requests.first
      assert_equal "/indexnow", request.path
      assert_equal "application/json; charset=utf-8", request["Content-Type"]
      assert_equal KEY, JSON.parse(request.body)["key"]
      assert_equal ["api.indexnow.org", 443], fake.starts.first.first(2)
      assert fake.starts.first.last[:use_ssl]
    end
  end

  def test_rejected_statuses_are_not_retryable
    { 400 => "bad request", 403 => "key not valid", 422 => "do not belong to the host" }.each do |code, reason|
      error = assert_raises(SeoGeo::IndexNow::RejectedError) do
        with_http(FakeHttp.new(code)) { SeoGeo::IndexNow.deliver("www.example.com", ["https://www.example.com/a"], config: config) }
      end
      assert_equal code, error.status
      assert_includes error.message, reason
      assert_includes @log.string, "IndexNow #{code} for www.example.com"
    end
  end

  def test_429_and_5xx_are_retryable
    [429, 500, 503].each do |code|
      error = assert_raises(SeoGeo::IndexNow::RetryableError) do
        with_http(FakeHttp.new(code)) { SeoGeo::IndexNow.deliver("www.example.com", ["https://www.example.com/a"], config: config) }
      end
      assert_equal code, error.status
    end
  end

  def test_network_error_is_retryable
    raising = ->(*_args, **_opts) { raise Errno::ECONNREFUSED }
    Net::HTTP.stub(:start, raising) do
      assert_raises(SeoGeo::IndexNow::RetryableError) do
        SeoGeo::IndexNow.deliver("www.example.com", ["https://www.example.com/a"], config: config)
      end
    end
  end

  def test_key_validation
    assert_includes config(key: "short").errors, "indexnow.key must be 8-128 characters of a-zA-Z0-9- when indexnow.enabled"
    assert_includes config(key: "bad_key_with_underscore").errors.join, "indexnow.key"
    assert_includes config(batch_size: 10_001).errors.join, "indexnow.batch_size"
    assert_empty config.errors
  end

  def test_key_constraint
    request = Struct.new(:path_parameters).new({ indexnow_key: KEY })
    SeoGeo.reset!
    refute SeoGeo::IndexNow::KeyConstraint.matches?(request)
    SeoGeo.config.indexnow.key = KEY
    assert SeoGeo::IndexNow::KeyConstraint.matches?(request)
    SeoGeo.config.indexnow.key = "short"
    refute SeoGeo::IndexNow::KeyConstraint.matches?(Struct.new(:path_parameters).new({ indexnow_key: "short" }))
  ensure
    SeoGeo.reset!
  end
end

class IndexNowModelTest < Minitest::Test
  # Minimal stand-in for an ActiveRecord model: records after_commit hooks and runs them on demand.
  class FakeRecord
    extend SeoGeo::Model

    class << self
      attr_accessor :hooks

      def after_commit(on:, &block)
        (self.hooks ||= []) << [on, block]
      end
    end

    attr_accessor :id, :published, :saved_changes, :new_record, :destroyed

    def initialize(id:, published: true, saved_changes: {}, new_record: false, destroyed: false)
      @id = id
      @published = published
      @saved_changes = saved_changes
      @new_record = new_record
      @destroyed = destroyed
    end

    def published? = published
    def previously_new_record? = new_record
    def destroyed? = destroyed

    def commit!
      self.class.hooks.each { |_on, block| instance_exec(&block) }
    end
  end

  def model(**options)
    Class.new(FakeRecord) { seo_geo_indexnow(**options) }
  end

  def capture_submissions(&block)
    calls = []
    SeoGeo::IndexNow.stub(:submit, ->(urls) { calls << urls }, &block)
    calls
  end

  def test_publish_registers_create_and_update
    klass = model(on: :publish, url: ->(record) { "/posts/#{record.id}" })
    assert_equal [%i[create update]], klass.hooks.map(&:first)
  end

  def test_publish_submits_only_published_or_just_unpublished
    klass = model(on: :publish, url: ->(record) { "/posts/#{record.id}" })
    calls = capture_submissions do
      klass.new(id: 1).commit!
      klass.new(id: 2, published: false).commit!
      klass.new(id: 3, published: false, saved_changes: { "published" => [true, false] }).commit!
      klass.new(id: 4, published: false, saved_changes: { "published_at" => [Time.at(0), nil] }).commit!
    end
    assert_equal ["/posts/1", "/posts/3", "/posts/4"], calls
  end

  def test_symbol_url_and_if_condition
    klass = Class.new(FakeRecord) do
      seo_geo_indexnow on: :update, url: :public_url, if: -> { id.even? }
      def public_url = "/p/#{id}"
    end
    calls = capture_submissions { [1, 2].each { |id| klass.new(id: id).commit! } }
    assert_equal ["/p/2"], calls
  end

  def test_errors_are_logged_not_raised
    klass = model(on: :create, url: ->(_record) { raise "no route" })
    log = StringIO.new
    SeoGeo::IndexNow.logger = Logger.new(log)
    klass.new(id: 1).commit!
    assert_includes log.string, "IndexNow submit failed"
  ensure
    SeoGeo::IndexNow.logger = nil
  end

  def test_invalid_options
    assert_raises(SeoGeo::ConfigurationError) { model(on: :save, url: :x) }
    assert_raises(SeoGeo::ConfigurationError) { model(on: :create, url: nil) }
  end
end
