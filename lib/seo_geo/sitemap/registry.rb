# frozen_string_literal: true

module SeoGeo
  module Sitemap
    CHANGEFREQS = %w[always hourly daily weekly monthly yearly never].freeze

    # One resolved +<url>+ entry. +loc+ is absolute; +lastmod+ is nil unless a real date was supplied
    # (seo_geo never invents +Time.now+).
    Url = Data.define(:loc, :lastmod, :priority, :changefreq)

    # One registered source: a static path or a record collection.
    #
    # @!attribute source [String, #call, #find_each, #each] path ("/about"), a lambda returning a scope (evaluated per
    #   request: +-> { Post.published }+ — the recommended form, no model is loaded at boot and dev reloads never
    #   leave a stale class behind) or a scope / enumerable of records
    # @!attribute batch [Boolean, nil] nil/true => +find_each+ when the scope has it (batches by primary key:
    #   +select+ must include +id+, +order+ is ignored); false => +each+, so the scope's own +order+ is kept
    # @!attribute path [#call, Symbol, nil] record -> path; required for collections
    # @!attribute lastmod [#call, Symbol, Time, Date, nil] date, record method name, or record -> date
    # @!attribute priority [Float, nil] 0.0..1.0
    # @!attribute changefreq [String, nil] one of {CHANGEFREQS}
    # @!attribute hosts [Array<String>, nil] hosts whose sitemap lists the entry; nil => canonical host only
    # @!attribute noindex [Boolean] declared noindex (static paths only): never listed in sitemap.xml or
    #   llms.txt, and the head helper renders robots noindex for it
    # @!attribute index [Boolean] declared indexable under {Configuration#default_noindex}; without it a
    #   +default_noindex+ site lists nothing (see {SeoGeo::Publication})
    # @!attribute match [Regexp, #call, nil] collections only: which request paths belong to the collection
    #   (+->(path) { ... }+ or a Regexp over the path). With +index: true+ it is what makes the head of a record
    #   page indexable under +default_noindex+ ({SeoGeo::Publication.declared_index?}); without it the head
    #   needs +seo index: true+ and +rake seo_geo:audit+ warns (+sitemap.collection_index+)
    # @!attribute markdown [Boolean, nil] true when the page also serves Markdown at +/path.md+ (its action includes
    #   {SeoGeo::Markdownable}). The llms.txt sitemap fallback links +.md+ only for true; nil/false => HTML URL.
    #   false also makes +rake seo_geo:audit+ skip the page's Markdown checks.
    Entry = Data.define(:source, :path, :lastmod, :priority, :changefreq, :hosts, :noindex, :index, :markdown, :match,
                       :batch) do
      # @param config [Configuration]
      # @return [Boolean]
      def markdown?(config)
        config.markdown.suffix_urls? && markdown == true
      end

      # @return [Boolean]
      def static?
        source.is_a?(String)
      end

      # @param host [String] request host
      # @param config [Configuration]
      # @return [Boolean]
      def for_host?(host, config)
        wanted = hosts ? hosts.map { |name| name.to_s.downcase } : [config.canonical_host]
        wanted.include?(host.to_s.downcase.sub(/:\d+\z/, ""))
      end

      # @param path [String] request path
      # @return [Boolean] true when +path+ is this entry's static path or matches its collection +match:+
      #   (a timed-out Regexp does not match: membership grants indexing, so failing safe means not granting it)
      def covers?(path)
        return RobotsPath.path(source) == RobotsPath.path(path) if static?
        return false if match.nil?
        return SafeRegexp.match?(match, RobotsPath.path(path), on_timeout: false) if match.is_a?(Regexp)

        match.call(RobotsPath.path(path)) ? true : false
      end
    end

    # Boot-time registry of sitemap sources. Collections are stored unevaluated and enumerated per request.
    #
    # @example config/initializers/seo_geo.rb
    #   SeoGeo.sitemap.draw do
    #     add "/", priority: 1.0, changefreq: "daily"
    #     add -> { Presentation.published }, path: ->(p) { "/p/#{p.slug}" }, lastmod: :updated_at
    #     exclude %r{\A/s/}
    #   end
    class Registry
      # @return [Array<Entry>]
      attr_reader :entries
      # @return [Array<String, Regexp>]
      attr_reader :exclusions

      def initialize
        @entries = []
        @exclusions = []
      end

      # Evaluates a block with this registry as +self+.
      # @return [self]
      def draw(&block)
        instance_eval(&block) if block
        self
      end

      # Registers a static path or a record collection.
      # @param path_or_scope [String, #find_each, #each]
      # @param path [#call, Symbol, nil] record -> path (collections only)
      # @param lastmod [#call, Symbol, Time, Date, nil]
      # @param priority [Numeric, nil] 0.0..1.0
      # @param changefreq [String, Symbol, nil] one of {CHANGEFREQS}
      # @param hosts [Array<String>, String, nil] nil => canonical host only
      # @param noindex [Boolean] declare a static path noindex: it stays out of sitemap.xml and llms.txt and
      #   the head helper renders robots noindex for it (see also {Configuration#noindex_paths})
      # @param index [Boolean] declare the entry indexable when {Configuration#default_noindex} is on
      #   (the registry counterpart of a controller's +seo index: true+)
      # @param markdown [Boolean, nil] true => the llms.txt fallback links +/path.md+ (action includes
      #   {SeoGeo::Markdownable}); false => also skip the audit's Markdown checks; nil => HTML URL
      # @param match [Regexp, #call, nil] collections only: Regexp or +->(path) { bool }+ telling which request
      #   paths are records of this collection, so +index: true+ reaches their head too
      # @param batch [Boolean, nil] collections only: false iterates with +each+ (keeps +order+, loads all records);
      #   default uses +find_each+ when available (+select+ must include +id+, +order+ is ignored)
      # @raise [ConfigurationError] on invalid arguments
      # @return [Entry]
      def add(path_or_scope, path: nil, lastmod: nil, priority: nil, changefreq: nil, hosts: nil, noindex: false, index: false,
              markdown: nil, match: nil, batch: nil)
        raise ConfigurationError, "noindex: is only valid for static paths" if noindex && !path_or_scope.is_a?(String)
        raise ConfigurationError, "match: is only valid for collections" if match && path_or_scope.is_a?(String)
        raise ConfigurationError, "batch: is only valid for collections" if !batch.nil? && path_or_scope.is_a?(String)
        if match && !(match.is_a?(Regexp) || match.respond_to?(:call))
          raise ConfigurationError, "match: must be a Regexp or respond to #call"
        end
        raise ConfigurationError, "noindex: and index: are mutually exclusive" if noindex && index

        if path_or_scope.is_a?(String)
          raise ConfigurationError, "sitemap path #{path_or_scope.inspect} must start with /" unless path_or_scope.start_with?("/")
          raise ConfigurationError, "path: is only valid for collections" if path
        else
          unless path_or_scope.respond_to?(:call) || path_or_scope.respond_to?(:find_each) || path_or_scope.respond_to?(:each)
            raise ConfigurationError, "sitemap source must be a path String, a lambda returning a scope, or respond to #find_each/#each"
          end
          raise ConfigurationError, "collections need path: (a callable or a record method name)" unless path
        end
        if priority && !(priority.is_a?(Numeric) && priority.between?(0, 1))
          raise ConfigurationError, "sitemap priority must be between 0.0 and 1.0 (got #{priority.inspect})"
        end
        if changefreq && !CHANGEFREQS.include?(changefreq.to_s)
          raise ConfigurationError, "sitemap changefreq must be one of #{CHANGEFREQS.join(", ")}"
        end

        entry = Entry.new(source: path_or_scope, path: path, lastmod: lastmod, priority: priority&.to_f,
                          changefreq: changefreq&.to_s, hosts: hosts && Array(hosts).map(&:to_s), noindex: noindex == true,
                          index: index == true, markdown: markdown.nil? ? nil : markdown == true, match: match,
                          batch: batch)
        @entries << entry
        entry
      end

      # Excludes paths from every sitemap (user-generated/share pages, duplicates).
      # @param patterns [Array<String, Regexp>] exact paths or regexps matched against the path
      # @return [void]
      def exclude(*patterns)
        @exclusions.concat(patterns.flatten)
      end

      # @param path [String]
      # @return [Boolean] true when a static entry for +path+ was added with +noindex: true+
      def noindex?(path)
        PathMatch.any?(@entries.select(&:noindex).map(&:source), path)
      end

      # @param path [String]
      # @param host [String, nil] request host; entries added with +hosts:+ count only there (nil => any host)
      # @param config [Configuration] resolves +hosts: nil+ to the canonical host
      # @return [Boolean] true when an entry added with +index: true+ covers +path+ on +host+: a static path, or
      #   a collection whose +match:+ accepts it
      def index?(path, host: nil, config: SeoGeo.config)
        @entries.any? { |entry| entry.index && (host.nil? || entry.for_host?(host, config)) && entry.covers?(path) }
      end

      # @return [Array<Entry>] collections added with +index: true+ but no +match:+ — their record pages are
      #   in sitemap.xml while the head cannot know they are declared indexable
      def unmatched_index_collections
        @entries.select { |entry| entry.index && !entry.static? && entry.match.nil? }
      end

      # @param path [String]
      # @return [Boolean] true when a static entry for +path+ was added with +markdown: false+
      def markdown_disabled?(path)
        PathMatch.any?(@entries.select { |entry| entry.static? && entry.markdown == false }.map(&:source), path)
      end

      # @param path [String] compared like every declaration ({PathMatch}); a Regexp that times out excludes
      # @return [Boolean]
      def excluded?(path)
        PathMatch.any?(@exclusions, path)
      end

      # Enumerates resolved URLs for one host. The sitemaps controller streams these into XML,
      # splitting into a sitemap index above 50,000 URLs.
      # @param host [String] request host
      # @param config [Configuration]
      # @yieldparam url [Url]
      # @return [Enumerator<Url>] when no block is given
      def each_url(host, config: SeoGeo.config)
        return enum_for(:each_url, host, config: config) unless block_given?

        origin = config.origin_for(host)
        entries.each do |entry|
          next if entry.noindex || !entry.for_host?(host, config)
          next if config.default_noindex && !entry.index

          each_record(entry) do |record|
            relative = record ? resolve(entry.path, record) : entry.source
            next if relative.nil? || excluded?(relative.to_s) || config.noindex_path?(relative.to_s)

            lastmod = entry.lastmod.is_a?(Symbol) || entry.lastmod.respond_to?(:call) ? resolve(entry.lastmod, record) : entry.lastmod
            yield Url.new(loc: config.canonical_url("#{origin}#{relative}"), lastmod: lastmod,
                          priority: entry.priority, changefreq: entry.changefreq)
          end
        end
      end

      # Removes every entry and exclusion (tests, code reloading).
      # @return [void]
      def clear
        @entries.clear
        @exclusions.clear
      end

      private

      def each_record(entry, &block)
        return yield(nil) if entry.static?

        source = entry.source.respond_to?(:call) ? entry.source.call : entry.source
        if entry.batch != false && source.respond_to?(:find_each)
          source.find_each(&block)
        else
          source.each(&block)
        end
      end

      def resolve(callable_or_name, record)
        return nil if callable_or_name.nil? || record.nil?
        return record.public_send(callable_or_name) if callable_or_name.is_a?(Symbol)

        callable_or_name.call(record)
      end
    end
  end
end
