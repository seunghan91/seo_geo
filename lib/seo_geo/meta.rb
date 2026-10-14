# frozen_string_literal: true

require "uri"
require "erb"
require "json"
require "meta-tags"

module SeoGeo
  # Resolves the head tags of one request from the configuration, the controller's +seo(...)+
  # call and the page copy. Pure Ruby (no view), so the rules are unit-testable:
  #
  # - title: +seo title:+ > app +set_meta_tags title:+ > page title > site name, rendered once through
  #   {Configuration#format_title} (the only title template).
  # - description: +seo description:+ > page description > site description, truncated by
  #   {Configuration#truncate_description}.
  # - canonical: {Configuration#canonical_url} of the request URL (aliases and query folded), or of
  #   +seo canonical: "/path"+; +seo canonical: false+ drops it. With +locales+, a non-default locale's
  #   canonical is its own hreflang URL (self-referencing, like the hreflang alternates).
  # - robots: noindex when the host policy is not indexable (every host outside indexable_environments),
  #   when +seo noindex: true+, or when +default_noindex+ is on and the controller did not call +seo index: true+.
  class Meta
    # Per-request values set by the controller ({SeoGeo::Controller#seo}) or views.
    State = Struct.new(:title, :description, :image, :noindex, :index, :canonical, :page, :type,
                       :markdown, :json_ld, keyword_init: true) do
      def initialize(**)
        super
        self.json_ld ||= []
      end
    end

    # @return [Configuration]
    attr_reader :config
    # @return [State]
    attr_reader :state
    # @return [String] the request URL
    attr_reader :url
    # @return [Symbol, nil]
    attr_reader :locale

    # @param config [Configuration]
    # @param url [String] absolute request URL (+request.url+)
    # @param locale [Symbol, String, nil] current locale (+I18n.locale+)
    # @param state [State]
    # @param app_title [String, nil] title set through meta-tags' +set_meta_tags+ / +title+ helpers
    # @param markdown_available [Boolean] whether this request's action serves Markdown
    #   ({SeoGeo::Controller#seo_geo_markdown_available?}); +seo markdown: true+ overrides it
    def initialize(url:, config: SeoGeo.config, locale: nil, state: State.new, app_title: nil, markdown_available: true)
      @config = config
      @url = url.to_s
      @locale = (locale || config.site.default_locale)&.to_sym
      @state = state
      @app_title = app_title
      @markdown_available = markdown_available
    end

    # @return [Page, nil]
    def page
      return @page if defined?(@page)

      @page = case state.page
              when nil then nil
              when Page then state.page
              else SeoGeo.page(state.page, locale: locale)
              end
    end

    # @return [String, nil] title without the site suffix
    def title
      [state.title, @app_title, page&.title, config.site.name].find { |value| present?(value) }&.to_s
    end

    # @return [String, nil] the +<title>+ text
    def full_title
      title && config.format_title(title)
    end

    # @return [String, nil]
    def description
      config.truncate_description([state.description, page&.description, config.site.description].find { |value| present?(value) })
    end

    # @return [String, nil] lower-case request host
    def host
      URI.parse(url).host&.downcase
    rescue URI::InvalidURIError
      nil
    end

    # @return [HostPolicy]
    def host_policy
      config.host_policy(host.to_s)
    end

    # @return [Boolean] true outside indexable environments and on non-indexable hosts
    def environment_noindex?
      return false if host_policy.indexable

      UndeclaredHost.warn_once(host, config: config)
      true
    end

    # @return [Boolean] also true for paths declared noindex ({Configuration#noindex_paths} or sitemap
    #   +add path, noindex: true+), even when the controller called +seo index: true+
    def noindex?
      return true if environment_noindex? || state.noindex == true || declared_noindex?

      config.default_noindex ? !(state.index == true || declared_index?) : false
    end

    # @return [String, nil] canonical URL with aliases/query folded; nil when disabled
    def canonical
      return @canonical if defined?(@canonical)

      @canonical = if state.canonical == false then nil
                   elsif present?(state.canonical) then config.canonical_url(state.canonical.to_s)
                   elsif localized? then locale_url(locale, base_canonical)
                   else base_canonical
                   end
    end

    # @return [Array<Hash{Symbol => String}>] +{hreflang:, href:}+ for every locale plus x-default
    def alternates
      return [] unless localized? && canonical && state.canonical.nil?

      links = config.locales.map { |name| { hreflang: name.to_s, href: locale_url(name, base_canonical) } }
      x_default = config.effective_x_default_locale
      links << { hreflang: "x-default", href: locale_url(x_default, base_canonical) } if x_default
      links
    end

    # URL of the Markdown version advertised with +<link rel="alternate" type="text/markdown">+:
    # +/+ -> +/index.md+, +/docs/a+ -> +/docs/a.md+ (query kept). nil when Markdown is off, the page
    # is noindex or has no canonical, or the action does not serve Markdown (+seo markdown: true+ forces it).
    # @return [String, nil]
    def markdown_url
      return nil unless config.markdown.suffix_urls? && state.markdown != false && canonical && !noindex?
      return nil unless state.markdown == true || @markdown_available

      self.class.markdown_url_for(canonical)
    end

    # @param url [String] absolute URL
    # @return [String] the +.md+ URL for it
    def self.markdown_url_for(url)
      uri = URI.parse(url)
      path = uri.path.to_s
      uri.path = path.empty? || path.end_with?("/") ? "#{path.chomp("/")}/index.md" : "#{path}.md"
      uri.to_s
    end

    # @return [String, nil] absolute OG image URL (+seo image:+ > page +image+ > og_image.fallback_url)
    def image_url
      image = state.image
      image = image[:url] || image["url"] if image.is_a?(Hash)
      image ||= page&.extra&.dig(:image)
      image ||= config.og_image.fallback_url
      return nil unless present?(image)

      absolute(image.to_s)
    end

    # @return [Hash] options for meta-tags' renderer (everything except +title+)
    def tags
      tags = { description: description, canonical: canonical, alternate: alternate_links }
      if noindex?
        tags[:noindex] = true
        tags[:nofollow] = true if environment_noindex?
      end
      tags[:og] = open_graph
      tags[:twitter] = twitter
      tags.merge(config.verification.meta_tags.transform_keys(&:to_sym)).compact
    end

    # @return [JsonLd] WebSite + Organization (when site.name is set), the page's FAQPage, then nodes
    #   added with +seo json_ld:+ / +seo_geo_json_ld+
    def json_ld
      document = JsonLd.new(config: config)
      if present?(config.site.name)
        document.website(in_language: locale&.to_s)
        document.organization
      end
      document.add(page.json_ld(url: canonical || "#{document.origin}/", config: config)) if page
      state.json_ld.each { |node| document.add(node) }
      document
    end

    private

    # one declaration drives robots meta, sitemap.xml and llms.txt.
    def declared_noindex?
      Publication.declared_noindex?(request_path, config: config)
    end

    # Under +default_noindex+, a path registered with +index: true+ for this host is indexable (same rule as
    # sitemap.xml): a static path or a record of a collection added with +match:+.
    def declared_index?
      Publication.declared_index?(host.to_s, request_path, config: config)
    end

    def request_path
      RobotsPath.path(url)
    end

    def localized?
      !config.locales.empty? && config.locales.map(&:to_sym).include?(locale)
    end

    def base_canonical
      @base_canonical ||= config.canonical_url(url)
    end

    def locale_url(name, base)
      return config.hreflang_url.call(name.to_sym, base) if config.hreflang_url
      return base if name.to_sym == config.site.default_locale.to_sym

      "#{base}#{base.include?("?") ? "&" : "?"}locale=#{ERB::Util.url_encode(name.to_s)}"
    end

    def alternate_links
      links = alternates.map { |link| { href: link[:href], hreflang: link[:hreflang] } }
      links << { href: markdown_url, type: "text/markdown" } if markdown_url
      links.empty? ? nil : links
    end

    def open_graph
      image = image_url
      {
        type: state.type || "website",
        site_name: config.site.name,
        title: title,
        description: description,
        url: canonical,
        locale: og_locale,
        image: image && { _: image, **image_size(image) }.compact
      }.compact
    end

    # +og:image:width/height+ only when the size is known: an explicit +seo image: {url:, width:, height:}+, an image
    # the gem renders (+/og/<key>.png+ on this origin while og_image is enabled => og_image.width x height), or
    # the fallback image with +og_image.fallback_width/height+. A wrong size is worse than none.
    def image_size(url)
      explicit = state.image
      if explicit.is_a?(Hash)
        width = explicit[:width] || explicit["width"]
        height = explicit[:height] || explicit["height"]
        return { width: width, height: height } if width && height
      end
      og = config.og_image
      return { width: og.width, height: og.height } if og.enabled? && gem_rendered?(url)
      return { width: og.fallback_width, height: og.fallback_height } if url == og.fallback_url && og.fallback_width && og.fallback_height

      {}
    end

    OG_IMAGE_PATH = %r{\A/og/[a-zA-Z0-9_-]{1,100}\.png\z} # GET /og/:key.png (OgImage::KEY_FORMAT)

    def gem_rendered?(url)
      uri = URI.parse(url)
      URI.parse(absolute("/")).host.to_s.casecmp?(uri.host.to_s) && uri.path.match?(OG_IMAGE_PATH)
    rescue URI::InvalidURIError
      false
    end

    def twitter
      image = image_url
      { card: image ? "summary_large_image" : "summary", title: title, description: description, image: image }.compact
    end

    # Open Graph wants language_TERRITORY: +ko+ => +ko_KR+, +en-GB+ => +en_GB+ ({Configuration#og_locale}).
    def og_locale
      config.og_locale(locale)
    end

    def absolute(value)
      return value if value.match?(%r{\Ahttps?://}i)

      "#{config.canonical_origin}#{value.start_with?("/") ? "" : "/"}#{value}"
    end

    def present?(value)
      !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
    end

    # View helpers, included into ActionView by the engine (initializer "seo_geo.helpers").
    module Helper
      FALLBACK_TIMEOUT_MS = 5000

      # The whole SEO head in one line: +<title>+, description, canonical, robots, hreflang, Markdown
      # alternate, verification metas, Open Graph/Twitter, JSON-LD and the crawler-fallback snippet.
      # Values set with meta-tags' +set_meta_tags+ still apply (seo_geo supplies the defaults), except
      # that the title always goes through +title_template+ and non-indexable environments always get noindex.
      #
      # @param page [Symbol, Page, nil] page copy for title/description/FAQ (defaults to +seo page:+)
      # @param json_ld [Boolean] emit the JSON-LD script
      # @param fallback [Boolean] emit the crawler-fallback hide/unhide snippet
      # @return [ActiveSupport::SafeBuffer]
      def seo_geo_head(page: nil, json_ld: true, fallback: true)
        meta = seo_geo_meta(page: page)
        parts = [meta.full_title && content_tag(:title, meta.full_title), seo_geo_render_meta_tags(meta)]
        parts << seo_geo_json_ld_tag(meta.json_ld) if json_ld && !meta.json_ld.empty?
        parts << content_for(:seo_geo_json_ld) if content_for?(:seo_geo_json_ld)
        parts << seo_geo_fallback_snippet if fallback
        safe_join(parts.compact, "\n")
      end

      # @param page [Symbol, Page, nil]
      # @return [Meta] resolved values for the current request (also handy for custom tags)
      def seo_geo_meta(page: nil)
        state = respond_to?(:seo_geo_state) ? seo_geo_state : State.new
        state.page = page if page
        app_title = respond_to?(:meta_tags) ? meta_tags[:title] : nil
        app_title = nil if app_title.is_a?(Array)
        Meta.new(config: SeoGeo.config, url: request.url, locale: seo_geo_locale,
                 state: state, app_title: app_title,
                 markdown_available: respond_to?(:seo_geo_markdown_available?) && seo_geo_markdown_available?)
      end

      # @return [String] value for +<html lang>+: the same locale as +og:locale+ and +WebSite.inLanguage+
      def seo_geo_html_lang
        seo_geo_locale.to_s
      end

      # @return [Symbol] +I18n.locale+ when +config.locales+ lists it, else +site.default_locale+
      #   ({Configuration#request_locale})
      def seo_geo_locale
        SeoGeo.config.request_locale(defined?(I18n) ? I18n.locale : nil)
      end

      # Adds nodes to this page's JSON-LD graph (rendered by {#seo_geo_head}). Call it from a view;
      # views render before the layout's head.
      # @param node [Hash, JsonLd]
      # @return [nil]
      def seo_geo_json_ld(node)
        seo_geo_state.json_ld << node if respond_to?(:seo_geo_state)
        nil
      end

      # A +<script type="application/ld+json">+ tag, escaped with +ERB::Util.json_escape+ and carrying
      # the CSP nonce when one is configured. Use it for extra scripts in +content_for(:seo_geo_json_ld)+.
      # @param data [Hash, JsonLd]
      # @return [ActiveSupport::SafeBuffer]
      def seo_geo_json_ld_tag(data)
        hash = data.is_a?(JsonLd) ? data.to_h : data
        json = ERB::Util.json_escape(JSON.generate(hash))
        content_tag(:script, json.html_safe, type: "application/ld+json", nonce: seo_geo_nonce) # rubocop:disable Rails/OutputSafety
      end

      private

      def seo_geo_render_meta_tags(meta)
        collection = respond_to?(:meta_tags) ? meta_tags : MetaTags::MetaTagsCollection.new
        collection.with_defaults(meta.tags) do
          collection[:title] = nil
          collection[:site] = nil
          if meta.noindex?
            %i[index follow].each { |key| collection.meta_tags.delete(key) }
            collection[:noindex] = true
            collection[:nofollow] = true if meta.environment_noindex?
          end
          MetaTags::Renderer.new(collection).render(self)
        end
      end

      # Hides [data-seo-fallback] while JavaScript runs; shows it again when the app has not called
      # window.SeoGeo.mounted() within FALLBACK_TIMEOUT_MS (bundle failed to load).
      def seo_geo_fallback_snippet
        script = "(function(w,d){var r=d.documentElement,m=false;r.classList.add(\"seo-geo-js\");" \
                 "w.SeoGeo=w.SeoGeo||{};w.SeoGeo.mounted=function(){m=true;r.classList.add(\"seo-geo-mounted\")};" \
                 "setTimeout(function(){if(!m)r.classList.remove(\"seo-geo-js\")},#{FALLBACK_TIMEOUT_MS})})(window,document)"
        style = ".seo-geo-js [data-seo-fallback]{display:none}" \
                "[data-seo-fallback]{max-width:720px;margin:0 auto;padding:32px 16px;line-height:1.6;" \
                "word-break:keep-all;overflow-wrap:break-word}"
        safe_join([content_tag(:script, script.html_safe, nonce: seo_geo_nonce), # rubocop:disable Rails/OutputSafety
                   content_tag(:style, style.html_safe, nonce: seo_geo_nonce)], "\n") # rubocop:disable Rails/OutputSafety
      end

      def seo_geo_nonce
        respond_to?(:content_security_policy_nonce) ? content_security_policy_nonce : nil
      end
    end
  end
end
