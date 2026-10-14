# frozen_string_literal: true

require "json"
require "date"
require "time"

module SeoGeo
  # Builds one schema.org +@graph+ document. Nodes get stable +@id+ anchors so they can reference
  # each other (+{ "@id" => "https://www.example.com/#organization" }+) and so the same node added
  # twice (layout + view) is emitted once — the later call wins.
  #
  # Anchors: site-wide nodes hang off the origin (+/#website+, +/#organization+); page nodes hang
  # off the page URL (+<url>#faq+, +#article+, +#breadcrumb+, +#video+, +#product+, +#profile+, +#app+).
  #
  # Keyword arguments are snake_case and become camelCase properties (+same_as+ -> +sameAs+);
  # nested +type:+/+id:+ become +@type+/+@id+; Date/Time values become ISO 8601; nil values are dropped;
  # root-relative URLs (+"/logo.png"+) in URL-like properties are made absolute against the origin.
  #
  # Each typed method checks the properties Google requires for that type and raises {InvalidNode}
  # listing every missing one. FAQPage is built for AI answers and Bing; Google shows FAQ rich results
  # only for government and health sites, so no rich result is promised.
  #
  # @example
  #   ld = SeoGeo::JsonLd.new
  #   ld.website.organization
  #   ld.article(headline: post.title, url: post_url(post), date_published: post.published_at)
  #   ld.to_json
  class JsonLd
    # Raised when a node lacks a property its type requires.
    class InvalidNode < ArgumentError; end

    CONTEXT = "https://schema.org"

    # @return [Hash{String => Array<String>}] required properties per +@type+ (Google structured data docs)
    REQUIRED = {
      "WebSite" => %w[name url],
      "Organization" => %w[name url],
      "SoftwareApplication" => %w[name],
      "WebApplication" => %w[name],
      "MobileApplication" => %w[name],
      "Article" => %w[headline],
      "BlogPosting" => %w[headline],
      "NewsArticle" => %w[headline],
      "BreadcrumbList" => %w[itemListElement],
      "VideoObject" => %w[name thumbnailUrl uploadDate],
      "Product" => %w[name],
      "ProfilePage" => %w[mainEntity],
      "FAQPage" => %w[mainEntity]
    }.freeze

    URL_KEYS = %w[url logo image thumbnailUrl contentUrl embedUrl item].freeze
    private_constant :URL_KEYS

    # @return [String] origin used for +@id+ anchors and absolute URLs
    attr_reader :origin

    # @param origin [String, nil] defaults to config.canonical_origin
    # @param config [Configuration]
    def initialize(origin: nil, config: SeoGeo.config)
      @config = config
      @origin = (origin || config.canonical_origin).to_s.chomp("/")
      @nodes = []
    end

    # @return [Array<Hash>] the graph nodes, in insertion order
    def nodes
      @nodes.dup
    end

    # @return [Boolean]
    def empty?
      @nodes.empty?
    end

    # Adds a raw node (string or symbol keys) or every node of another {JsonLd} / +@graph+ document.
    # Raw nodes of a known +@type+ are validated like the typed methods.
    # @param node [Hash, JsonLd, Array]
    # @return [self]
    def add(node)
      case node
      when JsonLd then node.nodes.each { |inner| push(inner) }
      when Array then node.each { |inner| add(inner) }
      when Hash
        normalized = normalize(node)
        graph = normalized["@graph"]
        graph ? graph.each { |inner| push(inner) } : push(normalized.except("@context"))
      when nil then nil
      else raise ArgumentError, "JSON-LD node must be a Hash or SeoGeo::JsonLd (got #{node.class})"
      end
      self
    end
    alias << add

    # @return [self]
    def website(name: @config.site.name, url: "#{origin}/", description: @config.site.description, **attrs)
      node("WebSite", "#{origin}/#website", name: name, url: url, description: description, **attrs)
    end

    # @return [self]
    def organization(name: @config.site.name, url: "#{origin}/", logo: @config.site.logo_url,
                     same_as: @config.site.same_as, **attrs)
      same_as = Array(same_as)
      node("Organization", "#{origin}/#organization", name: name, url: url, logo: logo,
                                                      same_as: same_as.empty? ? nil : same_as, **attrs)
    end

    # @param type [String] "SoftwareApplication", "WebApplication" or "MobileApplication"
    # @return [self]
    def software_application(name:, url: "#{origin}/", type: "SoftwareApplication", **attrs)
      node(type, anchor(url, "app"), name: name, url: url, **attrs)
    end

    # @return [self]
    def web_application(name:, **attrs)
      software_application(name: name, type: "WebApplication", **attrs)
    end

    # @param type [String] "Article", "BlogPosting" or "NewsArticle"
    # @return [self]
    def article(headline:, url: "#{origin}/", type: "Article", **attrs)
      node(type, anchor(url, "article"), headline: headline, url: url, main_entity_of_page: url, **attrs)
    end

    # @param items [Array<Array(String, String)>, Array<Hash>] +[name, url]+ pairs or +{name:, url:}+;
    #   the last item may omit its URL (the current page)
    # @return [self]
    def breadcrumb_list(items, url: "#{origin}/")
      elements = Array(items).each_with_index.map do |item, index|
        name, item_url = item.is_a?(Hash) ? [item[:name] || item["name"], item[:url] || item["url"]] : item
        raise InvalidNode, "BreadcrumbList item #{index + 1} needs a name" if blank?(name)

        { type: "ListItem", position: index + 1, name: name, item: item_url }
      end
      node("BreadcrumbList", anchor(url, "breadcrumb"), item_list_element: elements.empty? ? nil : elements)
    end

    # @return [self]
    def video_object(name:, thumbnail_url:, upload_date:, url: "#{origin}/", **attrs)
      node("VideoObject", anchor(url, "video"), name: name, thumbnail_url: thumbnail_url,
                                                upload_date: upload_date, **attrs)
    end

    # Google requires one of +offers+, +review+ or +aggregate_rating+ for product snippets.
    # @return [self]
    def product(name:, url: "#{origin}/", **attrs)
      unless %i[offers review aggregate_rating].any? { |key| attrs[key] }
        raise InvalidNode, "Product #{name.inspect} needs offers, review or aggregate_rating"
      end

      node("Product", anchor(url, "product"), name: name, url: url, **attrs)
    end

    # @param main_entity [Hash] the Person or Organization the page is about (+name:+ required)
    # @return [self]
    def profile_page(main_entity:, url: "#{origin}/", **attrs)
      entity = { type: "Person" }.merge(main_entity.transform_keys(&:to_sym))
      raise InvalidNode, "ProfilePage main_entity needs a name" if blank?(entity[:name])

      node("ProfilePage", anchor(url, "profile"), url: url, main_entity: entity, **attrs)
    end

    # @param faq [Array<Hash>] +{question:, answer:}+ items, e.g. {Page#faq}
    # @return [self]
    def faq_page(faq, url: "#{origin}/", **attrs)
      questions = Array(faq).each_with_index.map do |item, index|
        question = item[:question] || item["question"]
        answer = item[:answer] || item["answer"]
        raise InvalidNode, "FAQPage item #{index + 1} needs a question and an answer" if blank?(question) || blank?(answer)

        { type: "Question", name: question, accepted_answer: { type: "Answer", text: answer } }
      end
      node("FAQPage", anchor(url, "faq"), main_entity: questions.empty? ? nil : questions, **attrs)
    end

    # @return [Hash{String => Object}] +{"@context" => ..., "@graph" => [...]}+
    def to_h
      { "@context" => CONTEXT, "@graph" => nodes }
    end
    alias as_json to_h

    # Plain JSON. Use {SeoGeo::Meta::Helper#seo_geo_json_ld_tag} (or +ERB::Util.json_escape+) to put it in HTML.
    # @return [String]
    def to_json(*)
      JSON.generate(to_h)
    end

    # @param type [String] schema.org type
    # @param id [String, nil] +@id+
    # @return [self]
    def node(type, id, **attrs)
      push(normalize({ type: type, id: id }.merge(attrs)))
      self
    end

    private

    def push(hash)
      validate!(hash)
      @nodes.reject! { |existing| hash["@id"] && existing["@id"] == hash["@id"] }
      @nodes << hash
    end

    def validate!(hash)
      missing = REQUIRED.fetch(hash["@type"].to_s, []).select { |key| blank?(hash[key]) }
      return if missing.empty?

      raise InvalidNode, "#{hash["@type"]} #{hash["@id"]} is missing #{missing.join(", ")}"
    end

    def anchor(url, name)
      "#{absolute(url.to_s).sub(/#.*\z/, "")}##{name}"
    end

    def normalize(value, key = nil)
      case value
      when Hash
        value.each_with_object({}) do |(name, inner), out|
          property = property_name(name)
          normalized = normalize(inner, property)
          out[property] = normalized unless normalized.nil?
        end
      when Array then value.map { |inner| normalize(inner, key) }
      when Time, DateTime then value.iso8601
      when Date then value.iso8601
      when Symbol then value.to_s
      when String then URL_KEYS.include?(key) ? absolute(value) : value
      else value.respond_to?(:iso8601) ? value.iso8601 : value
      end
    end

    def property_name(name)
      return name if name.is_a?(String)
      return "@#{name}" if %i[type id context graph].include?(name)

      name.to_s.gsub(/_([a-z\d])/) { Regexp.last_match(1).upcase }
    end

    def absolute(value)
      value.start_with?("/") && !value.start_with?("//") ? "#{origin}#{value}" : value
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end

  # JSON-LD built from the page copy, so FAQPage always matches the visible FAQ.
  class Page
    # @param url [String, nil] absolute page URL used for +@id+ anchors; defaults to the canonical origin root
    # @param config [Configuration]
    # @return [JsonLd] a document holding the FAQPage node (empty when the page has no FAQ)
    def json_ld(url: nil, config: SeoGeo.config)
      document = JsonLd.new(config: config)
      return document if faq.empty?

      document.faq_page(faq, url: url || "#{document.origin}/")
    end
  end
end
