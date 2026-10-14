# frozen_string_literal: true

require "digest"
require "json"

module SeoGeo
  # Open Graph images served at +GET /og/:key.png+.
  #
  # A backend is any callable +(key, page, params) -> String+ returning PNG bytes (a Satori
  # sidecar, a vips composer, ...). Without one, the bundled {FerrumBackend} renders an ERB
  # card when the optional ferrum gem is installed. Results are cached in +Rails.cache+ for
  # +og_image.cache_ttl+ under a key that includes +og_image.template_version+; failures are never cached.
  #
  # Every cache miss costs a render (with ferrum, a Chrome launch), so the controller serves only
  # {.resolve_key known keys} and {.validated_params constrained params}, and at most
  # +og_image.max_concurrent+ renders run at once per process.
  module OgImage
    # Raised when no backend can render, or a backend returns something that is not a PNG.
    class RenderError < StandardError; end
    # Raised on a cache miss while +og_image.max_concurrent+ renders are already running.
    class Busy < RenderError; end

    SLOTS = Mutex.new
    @active_renders = 0

    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
    KEY_FORMAT = /\A[a-zA-Z0-9_-]{1,100}\z/

    module_function

    # @param key [String]
    # @param page [Page, nil] page copy for +key+ when one is defined
    # @param params [Hash{String => String}] permitted query parameters
    # @param config [Configuration]
    # @param cache [#fetch, nil] cache store; nil disables caching
    # @raise [RenderError]
    # @return [String] PNG bytes (binary)
    # @raise [Busy] when every render slot is taken
    def render(key, page: nil, params: {}, config: SeoGeo.config, cache: default_cache)
      produce = -> { with_render_slot(config.og_image.max_concurrent) { render_uncached(key, page, params, config) } }
      return produce.call if cache.nil?

      cache.fetch(cache_key(key, page, params, config), expires_in: config.og_image.cache_ttl) { produce.call }
    end

    # Route constraint for +GET /og/:key.png+. The engine is mounted at "/" before or after the app's routes,
    # so a request it does not want must not match at all (a controller 404 does not cascade): +/og/alice.png+
    # reaches the app's own +/og/:username.png+ unless OG images are enabled and +alice+ is a known key.
    # The resolved value is kept in +env+ for the controller, so +key_resolver+ runs once per request.
    #
    # A +key_resolver+ that raises claims the request (+true+) and leaves the error in +env+: the controller then
    # answers with the configured fallback (redirect to +og_image.fallback_url+, else 404) and logs once. Falling
    # through instead would hand a resolver outage to whatever app route matches next — a 404/500 that preview bots
    # cache, or the wrong image — and skip +fallback_url+ entirely.
    module RouteConstraint
      ENV_KEY = "seo_geo.og_key"
      ERROR_KEY = "seo_geo.og_key_error"

      module_function

      # @param request [ActionDispatch::Request]
      # @return [Boolean]
      def matches?(request)
        config = SeoGeo.config
        key = request.path_parameters[:key].to_s
        return false unless config.og_image.enabled? && KEY_FORMAT.match?(key)

        resolved = OgImage.resolve_key(key, config)
        request.env[ENV_KEY] = resolved if resolved
        resolved ? true : false
      rescue StandardError => e
        request.env[ERROR_KEY] = e
        true
      end
    end

    # @param key [String]
    # @return [Page, true, nil] truthy when +key+ is a {SeoGeo.pages} key, listed in +og_image.keys+ or
    #   accepted by +og_image.key_resolver+ (whose {Page} is returned); nil => 404
    def resolve_key(key, config)
      return true if config.og_image.keys.any? { |name| name.to_s == key }
      return true if SeoGeo.pages.keys.any? { |name| name.to_s == key }

      config.og_image.key_resolver&.call(key) || nil
    end

    # @param query [Hash] request query parameters
    # @return [Hash{String => String}, nil] permitted params that carry a constraint; nil when any value
    #   is not a String, is longer than +og_image.max_param_length+ or fails its constraint
    def validated_params(query, config)
      options = config.og_image
      constraints = options.param_constraints.transform_keys(&:to_s)
      names = options.permitted_params.map(&:to_s).select { |name| constraints.key?(name) }
      params = query.to_h.transform_keys(&:to_s).slice(*names)
      valid = params.all? do |name, value|
        value.is_a?(String) && value.length <= options.max_param_length && allowed_value?(constraints[name], value)
      end
      valid ? params : nil
    end

    # @return [Boolean] whole-value match for a Regexp, membership for an Array. A Regexp that exceeds
    #   {SafeRegexp::TIMEOUT} rejects the value (=> 400) instead of holding the worker.
    def allowed_value?(rule, value)
      return rule.map(&:to_s).include?(value) if rule.is_a?(Array)

      match = SafeRegexp.match(rule, value)
      !match.nil? && match.begin(0).zero? && match.end(0) == value.length
    rescue Regexp::TimeoutError, SafeRegexp::TooLong
      false
    end

    # Runs the block in one of +limit+ process-wide slots; never waits.
    # @raise [Busy] when all slots are taken
    def with_render_slot(limit)
      acquired = SLOTS.synchronize do
        next false if OgImage.active_renders >= limit

        OgImage.active_renders += 1
        true
      end
      raise Busy, "#{limit} OG image renders already running" unless acquired

      begin
        yield
      ensure
        SLOTS.synchronize { OgImage.active_renders -= 1 }
      end
    end

    class << self
      # @return [Integer] renders running right now in this process
      attr_accessor :active_renders
    end

    # @return [String] cache key covering template version, key, locale and permitted params
    def cache_key(key, page, params, config)
      digest = Digest::SHA256.hexdigest(JSON.generate(params.to_h.sort))[0, 16]
      ["seo_geo/og", config.og_image.template_version, key, page&.locale, digest].compact.join("/")
    end

    # @return [#call, nil] the configured backend, else ferrum when available
    def backend(config)
      config.og_image.backend || (config.og_image.ferrum_available? ? FerrumBackend.new(config: config) : nil)
    end

    # @return [#fetch, nil] Rails.cache when Rails is loaded
    def default_cache
      defined?(Rails) && Rails.respond_to?(:cache) ? Rails.cache : nil
    end

    def render_uncached(key, page, params, config)
      renderer = backend(config)
      raise RenderError, "no og_image.backend configured and the ferrum gem is not available" if renderer.nil?

      bytes = renderer.call(key, page, params)
      unless bytes.is_a?(String) && bytes.b.start_with?(PNG_SIGNATURE)
        raise RenderError, "og_image backend returned #{bytes.class} instead of PNG bytes"
      end

      bytes.b
    end
  end
end
