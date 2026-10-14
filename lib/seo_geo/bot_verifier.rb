# frozen_string_literal: true

require "ipaddr"
require "json"
require "net/http"
require "resolv"
require "uri"

module SeoGeo
  # Optional: checks whether a request that *claims* to be a crawler (by User-Agent) really comes from
  # that operator. A User-Agent is a claim, not an identity — anyone can send "Googlebot".
  #
  # seo_geo itself never uses this (or the User-Agent) for access decisions: robots.txt is the only
  # place the gem reads crawler names, Markdown is chosen by the Accept header, and every client gets
  # the same public content. Use the verifier only when your app must grant a bot something extra
  # (skip a rate limit, allow a paywalled preview), and then require +verified == true+.
  #
  # Methods (sources checked 2026-10-14):
  # - Reverse DNS + forward confirmation (PTR host ends in an operator domain, and that host resolves
  #   back to the same IP):
  #   - Googlebot: googlebot.com, google.com —
  #     https://developers.google.com/crawling/docs/crawlers-fetchers/verify-google-requests
  #     (googleusercontent.com is deliberately NOT accepted: it also names customer Google Cloud hosts and is
  #     documented only for user-triggered fetchers, not Googlebot)
  #   - Bingbot: search.msn.com — https://www.bing.com/toolbox/verify-bingbot
  #   - Applebot: applebot.apple.com — https://support.apple.com/en-us/119829
  #   - Yeti (Naver): naver.com — NOT documented by Naver (searchadvisor.naver.com only covers robots.txt);
  #     the suffix is common practice (PTR names like crawl.<ip>.web.naver.com). Treat as best effort.
  # - Published IP ranges (+{"prefixes":[{"ipv4Prefix"|"ipv6Prefix": CIDR}]}+), cached for +ttl+ seconds;
  #   when a refresh fails the old list is used for at most another +ttl+, then the result is +nil+:
  #   - OpenAI GPTBot / OAI-SearchBot / ChatGPT-User — https://developers.openai.com/api/docs/bots
  #     (openai.com/gptbot.json, searchbot.json, chatgpt-user.json)
  #   - Perplexity PerplexityBot / Perplexity-User — https://docs.perplexity.ai/guides/bots
  #   - Anthropic ClaudeBot / Claude-User / Claude-SearchBot — https://support.claude.com/en/articles/8896518
  #     (one list for all three: claude.com/crawling/bots.json)
  # - Everything else (CCBot, Meta, Bytespider, ...) => +verified: nil+ (no published method).
  #
  # Web Bot Auth (HTTP Message Signatures for bots, IETF draft-meunier-webbotauth-httpsig-protocol):
  # requests carrying +Signature-Agent+, or +Signature+ with +Signature-Input+, are reported as
  # +signed: true+. Verifying the signature is TODO — +signed+ says nothing about who signed.
  #
  # @example config/application.rb (opt-in; place after ActionDispatch::RemoteIp so proxies are honoured)
  #   config.middleware.use SeoGeo::BotVerifier::Middleware
  #   # later, in a controller:
  #   bot = request.env["seo_geo.bot"]   # nil for ordinary visitors
  #   skip_rate_limit if bot && bot[:verified] == true
  class BotVerifier
    ENV_KEY = "seo_geo.bot"
    DEFAULT_TTL = 24 * 60 * 60
    # Seconds a failed range download is not retried (avoids stacking timeouts behind the refresh lock).
    FAILURE_BACKOFF = 60

    OPENAI = "https://openai.com"
    PERPLEXITY = "https://www.perplexity.com"
    ANTHROPIC_RANGES = "https://claude.com/crawling/bots.json"

    # Verification method per User-Agent token: +dns:+ PTR suffixes, or +ranges:+ IP-range JSON URL.
    METHODS = {
      "Googlebot" => { dns: %w[googlebot.com google.com] },
      "Bingbot" => { dns: %w[search.msn.com] },
      "Applebot" => { dns: %w[applebot.apple.com] },
      "Yeti" => { dns: %w[naver.com] },
      "GPTBot" => { ranges: "#{OPENAI}/gptbot.json" },
      "OAI-SearchBot" => { ranges: "#{OPENAI}/searchbot.json" },
      "ChatGPT-User" => { ranges: "#{OPENAI}/chatgpt-user.json" },
      "PerplexityBot" => { ranges: "#{PERPLEXITY}/perplexitybot.json" },
      "Perplexity-User" => { ranges: "#{PERPLEXITY}/perplexity-user.json" },
      "ClaudeBot" => { ranges: ANTHROPIC_RANGES },
      "Claude-User" => { ranges: ANTHROPIC_RANGES },
      "Claude-SearchBot" => { ranges: ANTHROPIC_RANGES }
    }.freeze

    # Crawlers that fetch pages but are not in {Crawlers::ALL} (whose Apple entry is the robots-only
    # Applebot-Extended token).
    EXTRA_CRAWLERS = { "Applebot" => :search }.freeze

    # Default DNS resolver: Resolv with a 2-second timeout. Anything with +getnames(ip)+ and
    # +getaddresses(name)+ works.
    def self.default_resolver
      Resolv::DNS.new.tap { |dns| dns.timeouts = 2 }
    end

    # Default range fetcher: +(url) -> body+ over HTTPS with short timeouts; raises on non-200.
    DEFAULT_FETCHER = lambda do |url|
      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 5) do |http|
        http.get(uri.request_uri, "Accept" => "application/json", "User-Agent" => "seo_geo/#{SeoGeo::VERSION}")
      end
      raise IOError, "GET #{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    # @return [BotVerifier] process-wide instance used by {Middleware} when none is given
    def self.default
      @default ||= new
    end

    # @param resolver [#getnames, #getaddresses] DNS (tests inject a stub)
    # @param fetcher [#call] +(url) -> String+ JSON body (tests inject a stub)
    # @param ttl [Integer] seconds an IP-range list and a DNS answer stay cached
    # @param clock [#call] monotonic seconds (tests)
    def initialize(resolver: self.class.default_resolver, fetcher: DEFAULT_FETCHER, ttl: DEFAULT_TTL,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @resolver = resolver
      @fetcher = fetcher
      @ttl = ttl
      @clock = clock
      @ranges = {}
      @dns = {}
      @mutex = Mutex.new
      @refresh = Mutex.new
    end

    # @param user_agent [String, nil] User-Agent header
    # @param ip [String, nil] client IP
    # @param headers [Hash{String => String}] Rack env or header hash (for Web Bot Auth detection)
    # @return [Hash, nil] +{name:, purpose:, claimed:, verified:, signed:}+; nil when the request neither
    #   claims a known crawler nor carries Web Bot Auth headers. +verified+ is true/false, or nil when the
    #   operator publishes no verification method or the check could not run (DNS/range fetch failure).
    def verify(user_agent:, ip:, headers: {})
      name, purpose = identify(user_agent)
      signed = signed?(headers)
      return nil if name.nil? && !signed

      { name: name, purpose: purpose, claimed: !name.nil?, verified: name && verified?(name, ip), signed: signed }
    end

    # @param user_agent [String, nil]
    # @return [Array(String, Symbol), nil] token and purpose of the crawler the User-Agent claims
    def identify(user_agent)
      return nil if user_agent.nil? || user_agent.strip.empty?

      crawler = Crawlers.find(user_agent)
      crawler = nil if crawler&.token_only
      return [crawler.user_agent, crawler.purpose] if crawler

      token = EXTRA_CRAWLERS.keys.find { |name| user_agent.downcase.include?(name.downcase) }
      token && [token, EXTRA_CRAWLERS[token]]
    end

    # @param name [String] crawler token
    # @param ip [String, nil]
    # @return [Boolean, nil]
    def verified?(name, ip)
      method = METHODS[name]
      address = parse_ip(ip)
      return nil if method.nil?
      return false if address.nil?

      method[:dns] ? dns_verified?(address, method[:dns]) : in_ranges?(address, method[:ranges])
    end

    # @param headers [Hash]
    # @return [Boolean] true when Web Bot Auth headers are present (signature NOT verified)
    def signed?(headers)
      lookup = ->(name) { headers[name] || headers["HTTP_#{name.upcase.tr("-", "_")}"] || headers[name.downcase] }
      present = ->(value) { !value.nil? && !value.to_s.strip.empty? }
      present.call(lookup.call("Signature-Agent")) ||
        (present.call(lookup.call("Signature")) && present.call(lookup.call("Signature-Input")))
    end

    # Drops cached ranges and DNS answers.
    # @return [void]
    def clear_cache
      @mutex.synchronize do
        @ranges.clear
        @dns.clear
      end
    end

    private

    # A single host address (no CIDR notation); IPv4-mapped IPv6 is folded to IPv4.
    def parse_ip(ip)
      text = ip.to_s.strip
      return nil if text.empty? || text.include?("/")

      address = IPAddr.new(text)
      address.ipv4_mapped? ? address.native : address
    rescue IPAddr::Error
      nil
    end

    def dns_verified?(address, suffixes)
      key = [address.to_s, suffixes]
      cached(@dns, key) do
        names = @resolver.getnames(address.to_s).map { |name| name.to_s.downcase.chomp(".") }
        match = names.find { |name| suffixes.any? { |suffix| name == suffix || name.end_with?(".#{suffix}") } }
        match ? @resolver.getaddresses(match).any? { |forward| same_ip?(forward, address) } : false
      end
    rescue Resolv::ResolvError, Resolv::ResolvTimeout, SocketError, SystemCallError
      nil
    end

    def same_ip?(candidate, address)
      IPAddr.new(candidate.to_s) == address
    rescue IPAddr::Error
      false
    end

    def in_ranges?(address, url)
      prefixes = ranges(url)
      prefixes && prefixes.any? { |range| range.family == address.family && range.include?(address) }
    end

    # Cached prefixes for +url+. Refreshes are serialized (a slow, older response can never overwrite a
    # newer list). A failed refresh keeps the previous list for at most another +ttl+; nil means unknown.
    def ranges(url)
      entry = @mutex.synchronize { @ranges[url] }
      return entry[:value] if entry && entry[:expires] > now

      @refresh.synchronize do
        entry = @mutex.synchronize { @ranges[url] }
        return entry[:value] if entry && entry[:expires] > now

        begin
          value = parse_ranges(@fetcher.call(url))
          @mutex.synchronize { @ranges[url] = { value: value, expires: now + @ttl, stale_until: now + (2 * @ttl) } }
          value
        rescue StandardError
          stale = entry && entry[:stale_until] > now ? entry[:value] : nil
          retry_at = now + [FAILURE_BACKOFF, @ttl].min
          retry_at = [retry_at, entry[:stale_until]].min if stale
          @mutex.synchronize do
            @ranges[url] = { value: stale, expires: retry_at, stale_until: entry ? entry[:stale_until] : now }
          end
          stale
        end
      end
    end

    def parse_ranges(body)
      JSON.parse(body.to_s).fetch("prefixes").filter_map do |prefix|
        cidr = prefix["ipv4Prefix"] || prefix["ipv6Prefix"]
        cidr && IPAddr.new(cidr)
      end
    end

    def cached(store, key)
      entry = @mutex.synchronize { store[key] }
      return entry[:value] if entry && entry[:expires] > now

      value = yield
      @mutex.synchronize do
        store.shift if store.size >= 10_000
        store[key] = { value: value, expires: now + @ttl }
      end
      value
    end

    def now
      @clock.call
    end

    # Rack middleware: sets +env["seo_geo.bot"]+ (see {BotVerifier#verify}) and nothing else — it never
    # blocks, redirects or changes the response.
    class Middleware
      # @param app [#call]
      # @param verifier [BotVerifier]
      def initialize(app, verifier: BotVerifier.default)
        @app = app
        @verifier = verifier
      end

      def call(env)
        env[ENV_KEY] = @verifier.verify(user_agent: env["HTTP_USER_AGENT"], ip: client_ip(env), headers: env)
        @app.call(env)
      end

      private

      def client_ip(env)
        env["action_dispatch.remote_ip"]&.to_s || env["REMOTE_ADDR"]
      end
    end
  end
end
