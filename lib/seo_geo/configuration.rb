# frozen_string_literal: true

require "uri"
require "erb"

module SeoGeo
  # Raised by {Configuration#validate!} (at boot) and by registry DSLs on invalid input.
  class ConfigurationError < ArgumentError; end

  # Site identity used by meta tags, JSON-LD (WebSite/Organization) and llms.txt.
  class SiteOptions
    # @return [String, nil] site name; used as +%{site}+ in {Configuration#title_template}
    attr_accessor :name
    # @return [String, nil] one-sentence summary; the llms.txt blockquote and default description
    attr_accessor :description
    # @return [String, nil] absolute URL of the logo (Organization.logo)
    attr_accessor :logo_url
    # @return [Symbol] locale used for +<html lang>+ and when a page has no localized copy
    attr_accessor :default_locale
    # @return [Array<String>] Organization.sameAs profile URLs
    attr_accessor :same_as

    def initialize
      @name = nil
      @description = nil
      @logo_url = nil
      @default_locale = :en
      @same_as = []
    end
  end

  # Search-console ownership tokens. Each non-nil value becomes one meta tag (Daum: a robots.txt line).
  class VerificationOptions
    # @return [String, nil] +<meta name="google-site-verification">+
    attr_accessor :google
    # @return [String, nil] +<meta name="msvalidate.01">+
    attr_accessor :bing
    # @return [String, nil] +<meta name="naver-site-verification">+
    attr_accessor :naver
    # @return [String, nil] Daum webmaster PIN, emitted as +#DaumWebMasterTool:<pin>+ in robots.txt
    attr_accessor :daum_pin

    # @return [Hash{String => String}] meta name => content for every configured HTML token
    def meta_tags
      { "google-site-verification" => google, "msvalidate.01" => bing, "naver-site-verification" => naver }
        .reject { |_name, value| value.nil? || value.to_s.empty? }
    end
  end

  # Purpose-based crawler policy. One object drives robots.txt groups, the Content-Signal
  # header/line and (experimental) AIPREF Content-Usage.
  class CrawlerOptions
    POLICIES = %i[allow deny].freeze
    # Per-token overrides may also grant +:full_access+ (see {#override}).
    OVERRIDE_POLICIES = %i[allow deny full_access].freeze

    # @return [Symbol] :allow or :deny for training crawlers (default :allow)
    attr_accessor :training
    # @return [Symbol] :allow or :deny for search crawlers (default :allow)
    attr_accessor :search
    # @return [Symbol] :allow or :deny for user-triggered fetchers (default :allow)
    attr_accessor :user
    # @return [Hash{String => Symbol}] per-token policy overriding its purpose, e.g. {"Bytespider" => :deny}
    attr_reader :overrides

    def initialize
      @training = :allow
      @search = :allow
      @user = :allow
      @extra = Crawlers::PURPOSES.to_h { |purpose| [purpose, []] }
      @overrides = {}
    end

    # Adds a user-agent token to a purpose group (in addition to {Crawlers::DEFAULT_USER_AGENTS}).
    # @param purpose [Symbol] one of {Crawlers::PURPOSES}
    # @param user_agents [Array<String>]
    # @return [void]
    def add(purpose, *user_agents)
      raise ConfigurationError, "unknown crawler purpose #{purpose.inspect}" unless @extra.key?(purpose)

      @extra[purpose].concat(user_agents.flatten.map(&:to_s))
    end

    # @param user_agent [String] robots.txt token
    # @param policy [Symbol] :allow, :deny or :full_access. +:full_access+ (opt-in, never a default) gives the
    #   token its own group with +Allow: /+ and the allow exceptions — it **ignores every host +disallow+**
    #   (e.g. +"Mediapartners-Google"+ must see the pages it serves ads on). It still gets +Disallow: /+ wherever
    #   the whole host is closed (non-indexable host or environment, undeclared host).
    # @return [void]
    def override(user_agent, policy)
      @overrides[user_agent.to_s] = policy
    end

    # @param purpose [Symbol]
    # @return [Symbol] :allow or :deny
    def policy_for_purpose(purpose)
      case purpose
      when :training then training
      when :search then search
      when :user then user
      else raise ConfigurationError, "unknown crawler purpose #{purpose.inspect}"
      end
    end

    # @param purpose [Symbol]
    # @return [Array<String>] default plus added tokens, de-duplicated, in table order
    def user_agents(purpose)
      (Crawlers::DEFAULT_USER_AGENTS.fetch(purpose) + @extra.fetch(purpose)).uniq
    end

    # Effective policy for one token: override, else its purpose, else nil (not managed by seo_geo).
    # @param user_agent [String]
    # @return [Symbol, nil]
    def policy_for(user_agent)
      key = @overrides.keys.find { |token| token.casecmp?(user_agent.to_s) }
      return @overrides[key] if key

      purpose = Crawlers::PURPOSES.find { |name| user_agents(name).any? { |token| token.casecmp?(user_agent.to_s) } }
      purpose && policy_for_purpose(purpose)
    end

    # @return [Array<String>] validation messages
    def errors
      messages = Crawlers::PURPOSES.filter_map do |purpose|
        value = policy_for_purpose(purpose)
        "crawlers.#{purpose} must be :allow or :deny (got #{value.inspect})" unless POLICIES.include?(value)
      end
      @overrides.each do |token, value|
        next if OVERRIDE_POLICIES.include?(value)

        messages << "crawlers.override(#{token.inspect}) must be :allow, :deny or :full_access (got #{value.inspect})"
      end
      messages
    end
  end

  # llms.txt / llms-full.txt contents (https://llmstxt.org/).
  class LlmsTxtOptions
    # One link line: +- [title](url): description+. +page+ links take title/description from {SeoGeo.page}.
    #
    # @!attribute page [Symbol, nil] page key ({SeoGeo.page}); nil for a plain link
    # @!attribute title [String, nil] link text (nil => page title, else the path)
    # @!attribute path [String] path ("/pricing") or absolute URL
    # @!attribute description [String, nil] note after the link (nil => page description)
    # @!attribute section [String] H2 the link is listed under
    # @!attribute optional [Boolean] list under +## Optional+ (secondary, droppable by readers)
    # @!attribute hosts [Array<String>, nil] hosts whose llms.txt lists the link; nil => canonical host only
    # @!attribute markdown [Boolean, nil] link the +.md+ form. nil => page links follow
    #   {MarkdownOptions#enabled} (a registered page has copy for Markdown); plain links do not (most actions do
    #   not include {SeoGeo::Markdownable} and their +.md+ URL answers 406). URLs on other origins are never rewritten.
    Link = Data.define(:page, :title, :path, :description, :section, :optional, :hosts, :markdown) do
      # @param config [Configuration]
      # @return [Boolean] whether llms.txt links this entry's +.md+ URL
      def markdown_link?(config)
        config.markdown.suffix_urls? && (markdown.nil? ? !page.nil? : markdown == true)
      end
    end

    # @return [Boolean] serve /llms.txt and /llms-full.txt (false => 404)
    attr_accessor :enabled
    # @return [Boolean] serve /llms-full.txt (concatenated page Markdown)
    attr_accessor :full
    # @return [String, nil] Markdown placed after the blockquote: paragraphs, lists and headings. H1/H2 are demoted
    #   to H3 (the H1 is the site name, H2s are the link sections); H3 and deeper stay as written
    attr_accessor :details
    # @return [String] section used when none is given
    attr_accessor :default_section
    # @return [Array<Link>]
    attr_reader :links

    def initialize
      @enabled = true
      @full = true
      @details = nil
      @default_section = "Pages"
      @links = []
    end

    # Lists a registered page; its copy also goes into llms-full.txt.
    # @param key [Symbol, String] page key ({SeoGeo.page})
    # @param path [String] where the page is served
    # @param section [String, nil]
    # @param optional [Boolean]
    # @param hosts [Array<String>, String, nil]
    # @param markdown [Boolean, nil] link +/path.md+; nil => {MarkdownOptions#enabled}. Pass false when the
    #   action does not include {SeoGeo::Markdownable}.
    # @return [Link]
    def page(key, path:, section: nil, optional: false, hosts: nil, markdown: nil)
      add(Link.new(page: key.to_sym, title: nil, path: path.to_s, description: nil, section: section,
                   optional: optional, hosts: hosts && Array(hosts).map(&:to_s), markdown: markdown))
    end

    # Lists a plain link.
    # @param title [String]
    # @param path [String] path or absolute URL
    # @param description [String, nil]
    # @param section [String, nil]
    # @param optional [Boolean]
    # @param hosts [Array<String>, String, nil]
    # @param markdown [Boolean, nil] link +/path.md+ only when true (the action includes {SeoGeo::Markdownable});
    #   nil/false => the HTML URL
    # @return [Link]
    def link(title, path, description: nil, section: nil, optional: false, hosts: nil, markdown: nil)
      add(Link.new(page: nil, title: title.to_s, path: path.to_s, description: description, section: section,
                   optional: optional, hosts: hosts && Array(hosts).map(&:to_s), markdown: markdown))
    end

    # @return [Array<String>]
    def errors
      links.filter_map do |item|
        next if item.path.start_with?("/") || item.path.match?(%r{\Ahttps?://})

        "llms_txt link #{item.path.inspect} must be a path starting with / or an http(s) URL"
      end
    end

    private

    def add(item)
      @links << item
      item
    end
  end

  # IETF AIPREF (draft-ietf-aipref-vocab / -attach). Off by default because the drafts are not RFCs.
  class AiprefOptions
    # @return [Boolean] emit +Content-Usage+ header and robots.txt lines (experimental)
    attr_accessor :enabled

    def initialize
      @enabled = false
    end
  end

  # Markdown content negotiation (+Accept: text/markdown+ and +.md+ URLs).
  class MarkdownOptions
    # @return [Boolean]
    attr_accessor :enabled
    # @return [Boolean] add the +Content-Signal+ header to Markdown responses
    attr_accessor :content_signal_header
    # @return [Symbol, #call] :reverse_markdown, or a callable +(html) -> markdown+
    attr_accessor :converter
    # @return [String] CSS selector for the main content; the first match is converted, else +<body>+
    attr_accessor :selector
    # @return [Boolean] serve +/<path>.md+ through {Markdown::PathSuffix} (default true). The middleware rewrites
    #   every GET +*.md+ app-wide; set false when the app has its own +.md+ routes. Markdown is then reachable only
    #   with +Accept: text/markdown+, and the head, llms.txt and the audit stop using +.md+ URLs.
    attr_accessor :path_suffix

    def initialize
      @enabled = true
      @content_signal_header = true
      @converter = :reverse_markdown
      @selector = "main, [role=main]"
      @path_suffix = true
    end

    # @return [Boolean] Markdown is served at +/<path>.md+ URLs
    def suffix_urls?
      enabled && path_suffix != false
    end

    # @return [Array<String>]
    def errors
      messages = []
      unless converter == :reverse_markdown || converter.respond_to?(:call)
        messages << "markdown.converter must be :reverse_markdown or respond to #call"
      end
      messages << "markdown.selector must be a non-empty String" if selector.to_s.strip.empty?
      messages
    end
  end

  # IndexNow submission (one shared endpoint relays to Bing, Naver, Yandex, Seznam, Yep).
  class IndexNowOptions
    KEY_FORMAT = /\A[a-zA-Z0-9-]{8,128}\z/
    MAX_URLS_PER_REQUEST = 10_000

    # @return [String, nil] 8–128 chars of a-zA-Z0-9-; served at +/<key>.txt+
    attr_accessor :key
    # @return [String]
    attr_accessor :endpoint
    # @return [Boolean]
    attr_accessor :enabled
    # @return [Boolean, nil] nil = dry-run outside indexable environments
    attr_accessor :dry_run
    # @return [Integer] URLs per POST (protocol maximum 10,000)
    attr_accessor :batch_size

    def initialize
      @key = nil
      @endpoint = "https://api.indexnow.org/indexnow"
      @enabled = false
      @dry_run = nil
      @batch_size = MAX_URLS_PER_REQUEST
    end

    # @return [Array<String>]
    def errors
      messages = []
      if enabled && !KEY_FORMAT.match?(key.to_s)
        messages << "indexnow.key must be 8-128 characters of a-zA-Z0-9- when indexnow.enabled"
      end
      if %w[robots llms llms-full humans security ads app-ads].include?(key.to_s.downcase)
        messages << "indexnow.key #{key.inspect} collides with another /<name>.txt route"
      end
      unless batch_size.is_a?(Integer) && batch_size.between?(1, MAX_URLS_PER_REQUEST)
        messages << "indexnow.batch_size must be an Integer between 1 and #{MAX_URLS_PER_REQUEST}"
      end
      messages << "indexnow.endpoint must be an https URL" unless endpoint.to_s.start_with?("https://")
      messages
    end
  end

  # Open Graph image rendering.
  class OgImageOptions
    # @return [#call, nil] +(key, page, params) -> String (PNG bytes) | nil+; nil uses the built-in
    #   ferrum renderer when ferrum is available, else {#fallback_url}
    attr_accessor :backend
    # @return [String] part of the cache key; bump it to invalidate every cached image
    attr_accessor :template_version
    # @return [Integer]
    attr_accessor :width
    # @return [Integer]
    attr_accessor :height
    # @return [String, nil] absolute URL used when rendering fails (and as the page image when none is given)
    attr_accessor :fallback_url
    # @return [Integer, nil] real pixel size of {#fallback_url}; +og:image:width/height+ are emitted for the
    #   fallback image only when both are set (a static image is rarely exactly {#width} x {#height})
    attr_accessor :fallback_width
    # @return [Integer, nil] see {#fallback_width}
    attr_accessor :fallback_height
    # @return [Array<String>] query parameters passed to the backend and part of the cache key;
    #   every other parameter is ignored so arbitrary query strings cannot fill the cache.
    #   Each one needs a {#param_constraints} entry.
    attr_accessor :permitted_params
    # @return [Hash{String => Regexp, Array<String>}] per-parameter value constraint: a Regexp the whole
    #   value must match, or the list of allowed values. A value that fails it is a 400 without rendering.
    attr_accessor :param_constraints
    # @return [Integer] longest accepted parameter value (characters); longer values are a 400
    attr_accessor :max_param_length
    # @return [Array<String, Symbol>] keys served in addition to {SeoGeo.pages} keys; any other key is a 404
    attr_accessor :keys
    # @return [#call, nil] +(key) -> Page | true | nil+ for keys not known statically (e.g. records);
    #   nil/false => 404 without rendering, a {Page} becomes the card's page copy
    attr_accessor :key_resolver
    # @return [Integer] seconds a rendered image stays in the cache (+expires_in+)
    attr_accessor :cache_ttl
    # @return [Integer] renders allowed at once per process; a cache miss beyond it gets the fallback
    #   redirect (or a 503 with +Retry-After+) instead of queueing
    attr_accessor :max_concurrent
    # @return [String, nil] ERB template path for the built-in ferrum renderer; nil uses the bundled card
    attr_accessor :template
    # @return [Boolean, nil] whether +GET /og/:key.png+ is routed at all. nil (default) => only when {#backend}
    #   or {#template} is set; true also serves the bundled ferrum card. Unrouted, +/og/...+ falls through to
    #   the application's own routes.
    attr_accessor :enabled

    def initialize
      @backend = nil
      @template_version = "1"
      @width = 1200
      @height = 630
      @fallback_url = nil
      @fallback_width = nil
      @fallback_height = nil
      @permitted_params = []
      @param_constraints = {}
      @max_param_length = 100
      @keys = []
      @key_resolver = nil
      @cache_ttl = 7 * 24 * 60 * 60
      @max_concurrent = 2
      @template = nil
      @enabled = nil
    end

    # @return [Boolean] whether the OG route answers at all (see {#enabled})
    def enabled?
      enabled.nil? ? !(backend.nil? && template.nil?) : enabled == true
    end

    # @return [Boolean] whether the optional ferrum gem can be loaded
    def ferrum_available?
      return true if defined?(::Ferrum)

      require "ferrum"
      true
    rescue LoadError
      false
    end

    # @return [Array<String>]
    def errors
      messages = []
      messages << "og_image.backend must respond to #call" unless backend.nil? || backend.respond_to?(:call)
      %i[width height max_param_length cache_ttl max_concurrent].each do |name|
        value = public_send(name)
        messages << "og_image.#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
      end
      %i[fallback_width fallback_height].each do |name|
        value = public_send(name)
        messages << "og_image.#{name} must be a positive Integer or nil" unless value.nil? || (value.is_a?(Integer) && value.positive?)
      end
      messages << "og_image.permitted_params must be an Array" unless permitted_params.is_a?(Array)
      messages << "og_image.keys must be an Array" unless keys.is_a?(Array)
      messages << "og_image.key_resolver must respond to #call" unless key_resolver.nil? || key_resolver.respond_to?(:call)
      messages.concat(param_constraint_errors)
      messages << "og_image.template #{template.inspect} does not exist" if template && !File.file?(template.to_s)
      messages
    end

    private

    def param_constraint_errors
      return ["og_image.param_constraints must be a Hash"] unless param_constraints.is_a?(Hash)

      constraints = param_constraints.transform_keys(&:to_s)
      invalid = constraints.reject { |_name, rule| rule.is_a?(Regexp) || (rule.is_a?(Array) && !rule.empty?) }
      messages = invalid.keys.map { |name| "og_image.param_constraints[#{name.inspect}] must be a Regexp or a non-empty Array" }
      return messages unless permitted_params.is_a?(Array)

      permitted_params.map(&:to_s).reject { |name| constraints.key?(name) }.each do |name|
        messages << "og_image.permitted_params #{name.inspect} needs an og_image.param_constraints entry"
      end
      messages
    end
  end

  # Per-host crawl/index policy. Built by {Configuration#host}; unknown hosts get {.fail_closed}.
  #
  # @!attribute host [String] lower-case host name, no port
  # @!attribute indexable [Boolean] false => robots meta noindex and robots.txt +Disallow: /+
  # @!attribute disallow [Array<String>] path prefixes disallowed for every crawler group
  # @!attribute allow [Array<String>] path prefixes always allowed (allow_exceptions + share prefixes)
  # @!attribute sitemap [Boolean] serve /sitemap.xml for this host (false => 404)
  # @!attribute known [Boolean] false only for the fail-closed policy of an undeclared host
  HostPolicy = Data.define(:host, :indexable, :disallow, :allow, :sitemap, :known) do
    # @return [HostPolicy] policy for a host nobody declared: nothing indexable, no sitemap
    def self.fail_closed(host, allow: [])
      new(host: host, indexable: false, disallow: ["/"].freeze, allow: allow.dup.freeze, sitemap: false, known: false)
    end

    # @return [Boolean] true when robots.txt should disallow the whole host
    def disallow_all?
      !indexable
    end
  end

  # Root configuration object. Exposed as +SeoGeo.config+ and, in Rails, as +config.seo_geo+.
  #
  # @example
  #   SeoGeo.configure do |c|
  #     c.site.name = "Example"
  #     c.canonical_origin = "https://www.example.com"
  #     c.canonical_aliases = ["example.com"]
  #     c.host "www.example.com", disallow: ["/admin"]
  #     c.crawlers.training = :deny
  #   end
  class Configuration
    UNKNOWN_HOST_MODES = %i[fail_closed].freeze

    # @return [SiteOptions]
    attr_reader :site
    # @return [VerificationOptions]
    attr_reader :verification
    # @return [CrawlerOptions]
    attr_reader :crawlers
    # @return [AiprefOptions]
    attr_reader :aipref
    # @return [MarkdownOptions]
    attr_reader :markdown
    # @return [IndexNowOptions]
    attr_reader :indexnow
    # @return [OgImageOptions]
    attr_reader :og_image
    # @return [LlmsTxtOptions]
    attr_reader :llms_txt

    # @return [String, nil] scheme + host (+ port), no path, e.g. "https://www.example.com"
    attr_reader :canonical_origin
    # @return [Array<String>] alias hosts folded onto {#canonical_origin}
    attr_accessor :canonical_aliases
    # @return [Array<String>] hosts that keep their own canonical (e.g. a separate store host)
    attr_accessor :canonical_exclude_hosts
    # @return [Array<String>] query parameters kept in canonical URLs (all others are dropped)
    attr_accessor :canonical_keep_params

    # @return [Symbol] behaviour for undeclared hosts; only :fail_closed is supported
    attr_accessor :unknown_host
    # @return [Array<String>] path prefixes allowed even on disallowed/fail-closed hosts
    attr_accessor :allow_exceptions
    # @return [Array<String>] share-link prefixes (e.g. "/s/") left open so link-preview bots can read them
    attr_accessor :share_prefixes

    # @return [Array<Symbol>] locales emitted as hreflang alternates
    attr_accessor :locales
    # @return [Symbol, nil] locale used for +hreflang="x-default"+ (defaults to site.default_locale)
    attr_accessor :x_default_locale
    # @return [#call, nil] +(locale, canonical_url) -> String+; nil => +?locale=<locale>+
    attr_accessor :hreflang_url

    # @return [#call, String, nil] current environment name; nil => Rails.env / RACK_ENV
    attr_accessor :environment
    # @return [Array<String>] environments allowed to be indexed; everything else is noindex + Disallow: /
    attr_accessor :indexable_environments

    # @return [String] format string with %{title} and optional %{site}
    attr_accessor :title_template
    # @return [Integer] descriptions are truncated to this many characters
    attr_accessor :description_max_length
    # @return [Boolean] true => pages are noindex unless a controller opts in with +seo index: true+
    attr_accessor :default_noindex
    # @return [Integer] Cache-Control max-age (seconds) for robots.txt, sitemap.xml, llms.txt
    attr_accessor :cache_control_seconds
    # @return [Hash{Symbol => Boolean}, nil] explicit Content-Signal; nil derives it from {#crawlers}
    attr_accessor :content_signal
    # @return [Array<String, Regexp>] paths that are always noindex: exact path Strings or
    #   Regexps matched against the path. One declaration drives the robots meta, sitemap.xml and llms.txt,
    #   so the three cannot disagree. See {#noindex_path?}.
    attr_accessor :noindex_paths

    def initialize
      @site = SiteOptions.new
      @verification = VerificationOptions.new
      @crawlers = CrawlerOptions.new
      @aipref = AiprefOptions.new
      @markdown = MarkdownOptions.new
      @indexnow = IndexNowOptions.new
      @og_image = OgImageOptions.new
      @llms_txt = LlmsTxtOptions.new

      @canonical_origin = nil
      @canonical_aliases = []
      @canonical_exclude_hosts = []
      @canonical_keep_params = []

      @unknown_host = :fail_closed
      @allow_exceptions = ["/.well-known/"]
      @share_prefixes = []
      @hosts = {}

      @locales = []
      @x_default_locale = nil
      @hreflang_url = nil

      @environment = nil
      @indexable_environments = ["production"]

      @title_template = "%{title} | %{site}"
      @description_max_length = 160
      @default_noindex = false
      @cache_control_seconds = 3600
      @content_signal = nil
      @noindex_paths = []
    end

    # @param origin [String] e.g. "https://www.example.com"; a trailing slash is removed
    def canonical_origin=(origin)
      @canonical_origin = origin&.to_s&.chomp("/")
    end

    # @return [String, nil] host part of {#canonical_origin}
    def canonical_host
      canonical_uri&.host&.downcase
    end

    # Declares the policy for one host.
    # @param name [String] host name
    # @param indexable [Boolean]
    # @param disallow [Array<String>] path prefixes
    # @param allow [Array<String>] extra always-allowed prefixes (added to allow_exceptions/share_prefixes)
    # @param sitemap [Boolean, nil] nil => same as +indexable+
    # @return [void]
    def host(name, indexable: true, disallow: [], allow: [], sitemap: nil)
      key = normalize_host(name)
      raise ConfigurationError, "host #{name.inspect} is not a valid host name" if key.empty? || key.include?("/")

      @hosts[key] = { indexable: indexable, disallow: Array(disallow), allow: Array(allow),
                      sitemap: sitemap.nil? ? indexable : sitemap }
    end

    # @return [Array<String>] canonical host, aliases, excluded hosts and declared hosts
    def known_hosts
      ([canonical_host] + canonical_aliases + canonical_exclude_hosts + @hosts.keys)
        .compact.map { |name| normalize_host(name) }.uniq
    end

    # Resolves the effective policy for a request host, applying environment and fail-closed rules.
    # Defaults when a known host was not declared with {#host}: the canonical host and excluded hosts
    # are indexable with a sitemap; aliases are crawlable (so bots see the canonical link) without a sitemap.
    # @param name [String] request host (port is ignored)
    # @return [HostPolicy]
    def host_policy(name)
      key = normalize_host(name)
      always = (allow_exceptions + share_prefixes).uniq
      return HostPolicy.fail_closed(key, allow: always) unless known_hosts.include?(key)

      declared = @hosts[key] || default_host_options(key)
      indexable = declared[:indexable] && indexable_environment?
      HostPolicy.new(host: key, indexable: indexable, disallow: declared[:disallow].dup.freeze,
                     allow: (always + declared[:allow]).uniq.freeze,
                     sitemap: declared[:sitemap] && indexable, known: true)
    end

    # Folds any URL onto its canonical form: alias and unknown hosts -> {#canonical_origin}; excluded hosts
    # and hosts declared with {#host} (that are not aliases) keep their own host; query strings dropped except {#canonical_keep_params}; fragments dropped;
    # non-ASCII path characters percent-encoded.
    # @param url_or_path [String] absolute URL or path ("/a?b=1")
    # @return [String]
    def canonical_url(url_or_path)
      raise ConfigurationError, "canonical_origin is not configured" unless canonical_origin

      uri = URI.parse(encode_non_ascii(url_or_path.to_s))
      host = uri.host&.downcase
      origin = host && self_canonical_hosts.include?(host) ? "#{canonical_uri.scheme}://#{host}" : canonical_origin
      path = uri.path.to_s.empty? ? "/" : uri.path
      query = kept_query(uri.query)
      query ? "#{origin}#{path}?#{query}" : "#{origin}#{path}"
    end

    # @return [String] absolute origin for a host: canonical origin for the canonical host, else https://host
    def origin_for(name)
      key = normalize_host(name)
      key == canonical_host ? canonical_origin : "#{canonical_uri&.scheme || "https"}://#{key}"
    end

    # @return [String] the current environment name
    def environment_name
      value = environment.respond_to?(:call) ? environment.call : environment
      value ||= Rails.env if defined?(Rails) && Rails.respond_to?(:env)
      (value || ENV["RACK_ENV"] || "development").to_s
    end

    # @return [Boolean] false outside {#indexable_environments}: every host is noindex + Disallow: /
    def indexable_environment?
      indexable_environments.map(&:to_s).include?(environment_name)
    end

    # Default territory per language for Open Graph (+og:locale+ is language_TERRITORY).
    OG_TERRITORIES = { "ko" => "KR", "en" => "US", "ja" => "JP", "zh" => "CN", "de" => "DE", "fr" => "FR",
                       "es" => "ES", "it" => "IT", "pt" => "BR", "ru" => "RU", "vi" => "VN", "th" => "TH",
                       "id" => "ID", "nl" => "NL", "pl" => "PL", "tr" => "TR", "ar" => "SA", "hi" => "IN" }.freeze

    # The one locale rule for +<html lang>+, +WebSite.inLanguage+ and +og:locale+: the request's +I18n.locale+
    # only when {#locales} lists it, otherwise {SiteOptions#default_locale}. An app that does not use I18n
    # (+I18n.locale+ stays +:en+) keeps its configured language.
    # @param current [Symbol, String, nil] usually +I18n.locale+
    # @return [Symbol]
    def request_locale(current)
      names = Array(locales).map(&:to_sym)
      current && names.include?(current.to_sym) ? current.to_sym : site.default_locale.to_sym
    end

    # @param locale [Symbol, String, nil] +:ko+, +:"ko-KR"+, +"en_GB"+
    # @return [String, nil] +ko_KR+ / +en_GB+; a bare language gets its default territory ({OG_TERRITORIES}),
    #   nil when unknown
    def og_locale(locale)
      language, region = locale.to_s.split(/[-_]/, 2)
      return nil if language.nil? || language.empty?

      region ||= OG_TERRITORIES[language.downcase]
      region && "#{language.downcase}_#{region.upcase}"
    end

    # @return [Symbol, nil]
    def effective_x_default_locale
      x_default_locale || (locales.empty? ? nil : site.default_locale)
    end

    # @param title [String]
    # @return [String] title rendered through {#title_template}; the bare title when site.name is unset
    def format_title(title)
      return title.to_s if site.name.nil? || site.name.to_s.empty? || title.to_s == site.name.to_s

      format(title_template, title: title, site: site.name)
    end

    # @param text [String, nil]
    # @return [String, nil] text truncated on a word boundary to {#description_max_length} characters
    def truncate_description(text)
      return nil if text.nil?

      squished = text.to_s.gsub(/\s+/, " ").strip
      return squished if squished.length <= description_max_length

      cut = squished[0, description_max_length - 1]
      cut = cut.sub(/\s+\S*\z/, "") if cut.include?(" ")
      "#{cut}…"
    end

    # @return [Hash{Symbol => Boolean}] :search, :ai_input, :ai_train
    def content_signals
      return content_signal.to_h.transform_keys(&:to_sym) if content_signal

      { search: crawlers.search == :allow, ai_input: crawlers.user == :allow, ai_train: crawlers.training == :allow }
    end

    # @return [String] Cloudflare Content-Signal value, e.g. "search=yes, ai-input=yes, ai-train=no"
    def content_signal_value
      signals = content_signals
      { "search" => :search, "ai-input" => :ai_input, "ai-train" => :ai_train }
        .map { |name, key| "#{name}=#{signals[key] ? "yes" : "no"}" }.join(", ")
    end

    # @return [String, nil] AIPREF Content-Usage value (experimental), nil when aipref is disabled
    def content_usage_value
      return nil unless aipref.enabled

      signals = content_signals
      "train-ai=#{signals[:ai_train] ? "y" : "n"}, search=#{signals[:search] ? "y" : "n"}"
    end

    # True when +path+ is declared noindex through {#noindex_paths}. Percent-encoded paths are
    # decoded first, so "/%EA%B0%80" matches a declared "/가". Query strings are ignored.
    # @param path [String] path or absolute URL
    # @return [Boolean]
    def noindex_path?(path)
      PathMatch.any?(Array(noindex_paths), path)
    end

    # @return [Array<String>] every problem found; empty when valid
    def errors
      messages = []
      messages.concat(origin_errors)
      messages << "unknown_host must be one of #{UNKNOWN_HOST_MODES.inspect}" unless UNKNOWN_HOST_MODES.include?(unknown_host)
      (allow_exceptions + share_prefixes).each do |prefix|
        messages << "path prefix #{prefix.inspect} must start with /" unless prefix.to_s.start_with?("/")
      end
      @hosts.each do |name, options|
        (options[:disallow] + options[:allow]).each do |prefix|
          messages << "host #{name.inspect}: path prefix #{prefix.inspect} must start with /" unless prefix.to_s.start_with?("/")
        end
      end
      messages.concat(locale_errors)
      Array(noindex_paths).each do |pattern|
        next if pattern.is_a?(Regexp) || (pattern.is_a?(String) && pattern.start_with?("/"))

        messages << "noindex_paths entry #{pattern.inspect} must be a path String starting with / or a Regexp"
      end
      messages << "title_template must contain %{title}" unless title_template.to_s.include?("%{title}")
      unless description_max_length.is_a?(Integer) && description_max_length >= 50
        messages << "description_max_length must be an Integer >= 50"
      end
      unless cache_control_seconds.is_a?(Integer) && !cache_control_seconds.negative?
        messages << "cache_control_seconds must be a non-negative Integer"
      end
      messages << "hreflang_url must respond to #call" unless hreflang_url.nil? || hreflang_url.respond_to?(:call)
      messages.concat(crawlers.errors, markdown.errors, indexnow.errors, og_image.errors, llms_txt.errors)
    end

    # @raise [ConfigurationError] listing every problem
    # @return [self]
    def validate!
      problems = errors
      raise ConfigurationError, "invalid seo_geo configuration:\n- #{problems.join("\n- ")}" unless problems.empty?

      self
    end

    private

    def canonical_uri
      canonical_origin && URI.parse(canonical_origin)
    rescue URI::InvalidURIError
      nil
    end

    def normalize_host(name)
      name.to_s.downcase.strip.sub(/:\d+\z/, "")
    end

    # Hosts that are their own canonical: excluded hosts plus declared hosts that are not aliases.
    def self_canonical_hosts
      aliases = canonical_aliases.map { |name| normalize_host(name) }
      (canonical_exclude_hosts.map { |name| normalize_host(name) } + @hosts.keys) - aliases - [canonical_host]
    end

    # Options for a known host without its own +host(...)+ declaration. An alias serves the canonical site's
    # pages (folded canonical), so it inherits the canonical host's +indexable+, +disallow+ and +allow+: otherwise
    # robots.txt on +example.com+ would open +/admin+ (or the whole site) that +www.example.com+ closes. Aliases never
    # serve a sitemap.
    def default_host_options(key)
      if key == canonical_host || canonical_exclude_hosts.map { |name| normalize_host(name) }.include?(key)
        { indexable: true, disallow: [], allow: [], sitemap: true }
      elsif canonical_aliases.map { |name| normalize_host(name) }.include?(key) && @hosts[canonical_host]
        canonical = @hosts[canonical_host]
        { indexable: canonical[:indexable], disallow: canonical[:disallow], allow: canonical[:allow], sitemap: false }
      else
        { indexable: true, disallow: [], allow: [], sitemap: false }
      end
    end

    def kept_query(query)
      return nil if query.nil? || canonical_keep_params.empty?

      kept = query.split("&").select { |pair| canonical_keep_params.map(&:to_s).include?(pair.split("=", 2).first) }
      kept.empty? ? nil : kept.join("&")
    end

    def encode_non_ascii(value)
      value.gsub(/[^\x00-\x7F]+/) { |chunk| ERB::Util.url_encode(chunk) }
    end

    def origin_errors
      return ["canonical_origin is required (e.g. \"https://www.example.com\")"] if canonical_origin.nil?

      uri = canonical_uri
      if uri.nil? || !%w[http https].include?(uri.scheme) || uri.host.nil?
        ["canonical_origin must be an absolute http(s) URL (got #{canonical_origin.inspect})"]
      elsif !uri.path.to_s.empty? || uri.query || uri.fragment
        ["canonical_origin must not contain a path, query or fragment (got #{canonical_origin.inspect})"]
      else
        []
      end
    end

    def locale_errors
      return [] if locales.empty?

      messages = []
      names = locales.map(&:to_sym)
      unless names.include?(site.default_locale.to_sym)
        messages << "site.default_locale #{site.default_locale.inspect} must be listed in locales"
      end
      if x_default_locale && !names.include?(x_default_locale.to_sym)
        messages << "x_default_locale #{x_default_locale.inspect} must be listed in locales"
      end
      messages
    end
  end
end
