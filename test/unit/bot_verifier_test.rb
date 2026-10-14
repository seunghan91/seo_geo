# frozen_string_literal: true

require "test_helper"

class BotVerifierTest < Minitest::Test
  # Resolv-compatible stub: no network in tests.
  class FakeResolver
    attr_reader :calls

    def initialize(ptr = {}, forward = {})
      @ptr = ptr
      @forward = forward
      @calls = 0
    end

    def getnames(ip)
      @calls += 1
      Array(@ptr[ip])
    end

    def getaddresses(name)
      Array(@forward[name])
    end
  end

  GOOGLE_UA = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  GPT_UA = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; GPTBot/1.2; +https://openai.com/gptbot"
  RANGES = '{"creationTime":"2026-10-01","prefixes":[{"ipv4Prefix":"20.0.0.0/24"},{"ipv6Prefix":"2001:db8::/32"}]}'

  def setup
    @resolver = FakeResolver.new(
      { "66.249.66.1" => ["crawl-66-249-66-1.googlebot.com."], "6.6.6.6" => ["fake.googlebot.com.evil.net"],
        "7.7.7.7" => ["crawl.googlebot.com"], "17.1.1.1" => ["17-1-1-1.applebot.apple.com"] },
      { "crawl-66-249-66-1.googlebot.com" => ["66.249.66.1"], "crawl.googlebot.com" => ["66.249.66.9"],
        "17-1-1-1.applebot.apple.com" => ["17.1.1.1"] }
    )
    @fetches = []
    @now = 0
    @body = RANGES
    @verifier = SeoGeo::BotVerifier.new(resolver: @resolver, clock: -> { @now }, ttl: 100,
                                         fetcher: ->(url) { @fetches << url; raise IOError, "down" if @body.nil?; @body })
  end

  def test_reverse_dns_with_forward_confirmation
    result = @verifier.verify(user_agent: GOOGLE_UA, ip: "66.249.66.1")
    assert_equal({ name: "Googlebot", purpose: :search, claimed: true, verified: true, signed: false }, result)
    assert_equal false, @verifier.verify(user_agent: GOOGLE_UA, ip: "6.6.6.6")[:verified], "suffix must be a domain boundary"
    assert_equal false, @verifier.verify(user_agent: GOOGLE_UA, ip: "7.7.7.7")[:verified], "forward lookup must match"
    assert_equal false, @verifier.verify(user_agent: GOOGLE_UA, ip: "1.2.3.4")[:verified]
    assert_equal false, @verifier.verify(user_agent: GOOGLE_UA, ip: "not-an-ip")[:verified]
  end

  def test_dns_answers_are_cached
    2.times { @verifier.verify(user_agent: GOOGLE_UA, ip: "66.249.66.1") }
    assert_equal 1, @resolver.calls
    @now = 101
    @verifier.verify(user_agent: GOOGLE_UA, ip: "66.249.66.1")
    assert_equal 2, @resolver.calls
  end

  def test_applebot_is_identified_though_not_in_the_crawler_table
    result = @verifier.verify(user_agent: "Mozilla/5.0 (Macintosh) Safari/605.1.15 (Applebot/0.1)", ip: "17.1.1.1")
    assert_equal ["Applebot", :search, true], result.values_at(:name, :purpose, :verified)
  end

  def test_published_ranges_with_ttl_and_stale_fallback
    assert @verifier.verify(user_agent: GPT_UA, ip: "20.0.0.7")[:verified]
    refute @verifier.verify(user_agent: GPT_UA, ip: "20.0.1.7")[:verified]
    assert @verifier.verified?("GPTBot", "2001:db8::1")
    assert_equal ["https://openai.com/gptbot.json"], @fetches, "cached within the TTL"

    @now = 150
    @body = nil # refresh fails: keep the stale list (for at most another ttl)
    assert @verifier.verify(user_agent: GPT_UA, ip: "20.0.0.7")[:verified]
    assert_equal 2, @fetches.size
  end

  def test_unloadable_ranges_and_unverifiable_bots_are_nil
    @body = nil
    assert_nil @verifier.verify(user_agent: "ClaudeBot/1.0", ip: "20.0.0.7")[:verified]
    assert_equal ["https://claude.com/crawling/bots.json"], @fetches
    result = @verifier.verify(user_agent: "CCBot/2.0", ip: "20.0.0.7")
    assert_equal ["CCBot", :training, true, nil], result.values_at(:name, :purpose, :claimed, :verified)
  end

  def test_ordinary_visitors_and_robots_only_tokens
    assert_nil @verifier.verify(user_agent: "Mozilla/5.0 Safari", ip: "1.1.1.1")
    assert_nil @verifier.verify(user_agent: nil, ip: "1.1.1.1")
    assert_nil @verifier.identify("Google-Extended")
  end

  def test_web_bot_auth_headers_are_detected_not_verified
    result = @verifier.verify(user_agent: "Mozilla/5.0", ip: "1.1.1.1",
                              headers: { "HTTP_SIGNATURE_AGENT" => '"https://bot.example"' })
    assert_equal({ name: nil, purpose: nil, claimed: false, verified: nil, signed: true }, result)
    assert @verifier.signed?({ "Signature" => "sig1=:abc:", "Signature-Input" => "sig1=()" })
    refute @verifier.signed?({ "Signature" => "sig1=:abc:" })
  end

  def test_middleware_sets_env_and_passes_through
    seen = nil
    app = ->(env) { seen = env[SeoGeo::BotVerifier::ENV_KEY]; [200, {}, ["ok"]] }
    middleware = SeoGeo::BotVerifier::Middleware.new(app, verifier: @verifier)
    status, = middleware.call("HTTP_USER_AGENT" => GOOGLE_UA, "REMOTE_ADDR" => "66.249.66.1")
    assert_equal 200, status
    assert_equal true, seen[:verified]
    middleware.call("HTTP_USER_AGENT" => GOOGLE_UA, "REMOTE_ADDR" => "10.0.0.1", "action_dispatch.remote_ip" => "66.249.66.1")
    assert_equal true, seen[:verified], "ActionDispatch::RemoteIp wins over REMOTE_ADDR"
    middleware.call("HTTP_USER_AGENT" => "Mozilla/5.0", "REMOTE_ADDR" => "1.1.1.1")
    assert_nil seen
  end

  def test_every_method_names_a_crawler_the_verifier_can_identify
    SeoGeo::BotVerifier::METHODS.each_key do |token|
      assert_equal token, @verifier.identify("Mozilla/5.0 (compatible; #{token}/1.0)")&.first
    end
  end

  # review fixes
  def test_googleusercontent_is_not_googlebot
    resolver = FakeResolver.new({ "35.1.1.1" => ["x.bc.googleusercontent.com"] }, { "x.bc.googleusercontent.com" => ["35.1.1.1"] })
    verifier = SeoGeo::BotVerifier.new(resolver: resolver, fetcher: ->(_) { RANGES })
    assert_equal false, verifier.verified?("Googlebot", "35.1.1.1")
  end

  def test_stale_ranges_expire_after_a_second_ttl
    assert @verifier.verified?("GPTBot", "20.0.0.7")
    @body = nil
    @now = 150
    assert @verifier.verified?("GPTBot", "20.0.0.7"), "stale list used within 2x ttl"
    @now = 201
    assert_nil @verifier.verified?("GPTBot", "20.0.0.7"), "too stale => unknown"
  end

  def test_client_ip_must_be_a_single_address
    assert_equal false, @verifier.verified?("GPTBot", "20.0.0.7/24")
    assert @verifier.verified?("GPTBot", "::ffff:20.0.0.7"), "IPv4-mapped IPv6 is folded to IPv4"
  end

  def test_failed_downloads_back_off
    @body = nil
    2.times { assert_nil @verifier.verified?("GPTBot", "20.0.0.7") }
    assert_equal 1, @fetches.size
    @now = 61
    @body = RANGES
    assert @verifier.verified?("GPTBot", "20.0.0.7")
    assert_equal 2, @fetches.size
  end
end
