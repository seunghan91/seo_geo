# frozen_string_literal: true

module SeoGeo
  # Builds robots.txt for one request host from {Configuration#host_policy} and {Configuration#crawlers}.
  #
  # RFC 9309 §2.2.1: a crawler obeys only the most specific group that names it and ignores +*+.
  # So every named group carries the host's full rule list: allowed crawlers share the +*+ rule block
  # (several +User-agent:+ lines, one block), denied crawlers get +Disallow: /+ plus {Configuration#allow_exceptions}
  # and every host +disallow+, verbatim. Named groups do not inherit +*+, so a disallow more specific than an
  # allow exception (+/.well-known/private+, or any encoding of it such as +/.%77ell-known/private+) must be
  # repeated there; repeating all of them needs no prefix comparison that encodings could defeat.
  # An +Allow: /+-only group is emitted only for tokens the app explicitly overrides to +:full_access+
  # ({CrawlerOptions#override}); it re-opens host disallows to that bot by design. Closed hosts never get one.
  #
  # @example
  #   SeoGeo::Robots.new(SeoGeo.config, "www.example.com").to_s
  class Robots
    # @param config [Configuration]
    # @param host [String] request host
    def initialize(config, host)
      @config = config
      @host = host
      @policy = config.host_policy(host)
    end

    # @return [String] robots.txt body (ends with a newline)
    def to_s
      blocks = @policy.disallow_all? ? [closed_block] : open_blocks
      trailer = [*sitemap_lines, *daum_lines]
      text = blocks.map { |lines| lines.join("\n") }.join("\n\n")
      text = "#{text}\n\n#{trailer.join("\n")}" unless trailer.empty?
      "#{text}\n"
    end

    # @return [Array<String>] tokens sharing the +*+ rule block
    def allowed_user_agents
      managed_user_agents.select { |token| @config.crawlers.policy_for(token) == :allow }
    end

    # @return [Array<String>] tokens overridden to +:full_access+ (own group, +Allow: /+, host disallows ignored)
    def full_access_user_agents
      managed_user_agents.select { |token| @config.crawlers.policy_for(token) == :full_access }
    end

    # @return [Array<String>] tokens given +Disallow: /+
    def denied_user_agents
      managed_user_agents.select { |token| @config.crawlers.policy_for(token) == :deny }
    end

    private

    # Undeclared host, +indexable: false+ host, or a non-indexable environment.
    def closed_block
      ["User-agent: *", *@policy.allow.map { |prefix| "Allow: #{prefix}" }, "Disallow: /"]
    end

    def open_blocks
      blocks = [shared_block]
      denied = denied_user_agents
      unless denied.empty?
        blocks << [*denied.map { |token| "User-agent: #{token}" },
                   *@config.allow_exceptions.map { |prefix| "Allow: #{prefix}" }, "Disallow: /",
                   *@policy.disallow.uniq.map { |prefix| "Disallow: #{prefix}" }]
      end
      full = full_access_user_agents
      unless full.empty?
        blocks << [*full.map { |token| "User-agent: #{token}" }, "Allow: /",
                   *@config.allow_exceptions.map { |prefix| "Allow: #{prefix}" }]
      end
      blocks
    end

    def shared_block
      lines = ["User-agent: *", *allowed_user_agents.map { |token| "User-agent: #{token}" }]
      if @policy.disallow.empty?
        lines << "Allow: /"
      else
        lines.concat(@policy.allow.map { |prefix| "Allow: #{prefix}" })
        lines.concat(@policy.disallow.map { |prefix| "Disallow: #{prefix}" })
      end
      lines << "Content-Signal: #{@config.content_signal_value}"
      usage = @config.content_usage_value
      lines << "Content-Usage: #{usage}" if usage
      lines
    end

    def managed_user_agents
      tokens = Crawlers::PURPOSES.flat_map { |purpose| @config.crawlers.user_agents(purpose) }
      (tokens + @config.crawlers.overrides.keys).uniq { |token| token.downcase }
    end

    def sitemap_lines
      return [] unless @policy.sitemap

      ["Sitemap: #{@config.origin_for(@host)}/sitemap.xml"]
    end

    def daum_lines
      pin = @config.verification.daum_pin
      return [] if pin.nil? || pin.to_s.empty? || @policy.disallow_all?

      ["#DaumWebMasterTool:#{pin}"]
    end
  end
end
