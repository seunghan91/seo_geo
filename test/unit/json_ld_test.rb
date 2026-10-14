# frozen_string_literal: true

require "test_helper"

class JsonLdTest < Minitest::Test
  def setup
    @config = configured do |config|
      config.site.name = "Example"
      config.site.logo_url = "/logo.png"
      config.site.same_as = ["https://github.com/example"]
    end
    @ld = SeoGeo::JsonLd.new(config: @config)
  end

  def graph
    @ld.to_h.fetch("@graph")
  end

  def test_site_nodes_with_id_anchors_and_absolute_urls
    @ld.website.organization
    website, organization = graph
    assert_equal "https://www.example.com/#website", website["@id"]
    assert_equal "https://www.example.com/#organization", organization["@id"]
    assert_equal "https://www.example.com/logo.png", organization["logo"]
    assert_equal ["https://github.com/example"], organization["sameAs"]
    assert_equal "https://schema.org", @ld.to_h["@context"]
  end

  def test_same_id_is_emitted_once_and_later_wins
    @ld.website.website(description: "Second")
    assert_equal 1, graph.size
    assert_equal "Second", graph.first["description"]
  end

  def test_snake_case_keys_dates_and_nested_types
    @ld.article(headline: "Hello", url: "/posts/1", date_published: Date.new(2026, 10, 1),
                date_modified: Time.utc(2026, 10, 2, 3, 4, 5), author: { type: "Person", name: "Kim" },
                image: "/cover.png", publisher: { id: "https://www.example.com/#organization" })
    article = graph.first
    assert_equal "Article", article["@type"]
    assert_equal "https://www.example.com/posts/1#article", article["@id"]
    assert_equal "2026-10-01", article["datePublished"]
    assert_equal "2026-10-02T03:04:05Z", article["dateModified"]
    assert_equal({ "@type" => "Person", "name" => "Kim" }, article["author"])
    assert_equal "https://www.example.com/cover.png", article["image"]
    assert_equal({ "@id" => "https://www.example.com/#organization" }, article["publisher"])
    refute article.key?("description"), "nil values are dropped"
  end

  def test_every_supported_type
    @ld.web_application(name: "App", application_category: "ShoppingApplication", operating_system: "Web")
       .software_application(name: "Tool", url: "/tool")
       .breadcrumb_list([["Home", "/"], { name: "Docs", url: "/docs" }, ["Page"]], url: "/docs/page")
       .video_object(name: "Demo", thumbnail_url: "/t.png", upload_date: Date.new(2026, 1, 1), url: "/v")
       .product(name: "Plan", url: "/p", offers: { type: "Offer", price: "0", price_currency: "USD" })
       .profile_page(main_entity: { name: "Kim" }, url: "/u/kim")
       .faq_page([{ question: "Q?", answer: "A." }], url: "/faq")
    types = graph.map { |node| node["@type"] }
    assert_equal %w[WebApplication SoftwareApplication BreadcrumbList VideoObject Product ProfilePage FAQPage], types
    crumbs = graph[2]["itemListElement"]
    assert_equal [1, 2, 3], crumbs.map { |item| item["position"] }
    assert_equal "https://www.example.com/docs", crumbs[1]["item"]
    refute crumbs[2].key?("item")
    assert_equal "Person", graph[5]["mainEntity"]["@type"]
    assert_equal "https://www.example.com/faq#faq", graph[6]["@id"]
    assert_equal({ "@type" => "Answer", "text" => "A." }, graph[6]["mainEntity"].first["acceptedAnswer"])
  end

  def test_required_fields_raise
    assert_raises(SeoGeo::JsonLd::InvalidNode) { SeoGeo::JsonLd.new(config: configured).website }
    error = assert_raises(SeoGeo::JsonLd::InvalidNode) { @ld.video_object(name: "V", thumbnail_url: nil, upload_date: nil) }
    assert_includes error.message, "thumbnailUrl, uploadDate"
    assert_raises(SeoGeo::JsonLd::InvalidNode) { @ld.product(name: "No offer") }
    assert_raises(SeoGeo::JsonLd::InvalidNode) { @ld.faq_page([]) }
    assert_raises(SeoGeo::JsonLd::InvalidNode) { @ld.faq_page([{ question: "Q?", answer: "" }]) }
    assert_raises(SeoGeo::JsonLd::InvalidNode) { @ld.breadcrumb_list([]) }
    assert_raises(SeoGeo::JsonLd::InvalidNode) { @ld.profile_page(main_entity: {}) }
    assert_raises(SeoGeo::JsonLd::InvalidNode) { @ld.add("@type" => "Article") }
  end

  def test_add_raw_nodes_graph_documents_and_other_builders
    other = SeoGeo::JsonLd.new(config: @config).website
    @ld.add("@context" => "https://schema.org", "@graph" => [{ "@type" => "Thing", "name" => "a" }])
    @ld << { type: "Thing", name: "b" } << other
    assert_equal [%w[Thing a], %w[Thing b], ["WebSite", "Example"]], graph.map { |node| [node["@type"], node["name"]] }
    assert_raises(ArgumentError) { @ld.add("string") }
  end

  def test_to_json_is_plain_json
    @ld.add("@type" => "Thing", "name" => "</script>")
    assert_equal "</script>", JSON.parse(@ld.to_json)["@graph"].first["name"]
  end

  def test_page_json_ld_matches_faq
    SeoGeo.reset!
    SeoGeo.config.canonical_origin = "https://www.example.com"
    SeoGeo.pages.register(:home, faq: [{ q: "Free?", a: "Yes." }])
    node = SeoGeo.page(:home).json_ld.to_h["@graph"].first
    assert_equal "https://www.example.com/#faq", node["@id"]
    assert_equal [["Free?", "Yes."]], node["mainEntity"].map { |q| [q["name"], q.dig("acceptedAnswer", "text")] }
    SeoGeo.pages.register(:empty, title: "No FAQ")
    assert_empty SeoGeo.page(:empty).json_ld
  ensure
    SeoGeo.reset!
  end
end
