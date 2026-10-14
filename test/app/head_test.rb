# frozen_string_literal: true

require "test_helper"
require "nokogiri"

# Through both dummies: seo_geo_head, JSON-LD, crawler fallback, controller seo(...).
class HeadTest < ActionDispatch::IntegrationTest
  def doc
    Nokogiri::HTML(response.body)
  end

  def graph
    scripts = doc.css('script[type="application/ld+json"]')
    JSON.parse(scripts.first.text).fetch("@graph")
  end

  def with_config(**values)
    previous = values.to_h { |name, _| [name, SeoGeo.config.public_send(name)] }
    values.each { |name, value| SeoGeo.config.public_send("#{name}=", value) }
    yield
  ensure
    previous.each { |name, value| SeoGeo.config.public_send("#{name}=", value) }
  end

  # an app that does not use I18n (I18n.locale stays :en) keeps site.default_locale :ko.
  def test_default_locale_wins_over_unlisted_i18n_locale
    default = SeoGeo.config.site.default_locale
    SeoGeo.config.site.default_locale = :ko
    with_config(locales: []) do
      I18n.with_locale(:en) { get "/" }
    end
    assert_equal "ko", doc.at_xpath("/html")["lang"]
    assert_equal "ko_KR", doc.at_css('meta[property="og:locale"]')["content"]
    assert_equal "ko", graph.find { |node| node["@type"] == "WebSite" }["inLanguage"]
  ensure
    SeoGeo.config.site.default_locale = default
  end

  def test_canonical_folds_alias_host_and_utm_params
    host! "example.com"
    get "/?utm_source=x&utm_medium=y"
    assert_response :success
    assert_equal ["https://www.example.com/"], doc.css('link[rel="canonical"]').map { |link| link["href"] }
    assert_equal "https://www.example.com/", doc.at_css('meta[property="og:url"]')["content"]
  end

  def test_single_title_through_template
    get "/"
    assert_equal ["Dummy home | Dummy"], doc.css("title").map(&:text)
    assert_equal "Dummy home", doc.at_css('meta[property="og:title"]')["content"]
    assert_equal "en", doc.at_css("html")["lang"]
  end

  def test_set_meta_tags_title_still_goes_through_template
    get "/head_pages/app_title"
    assert_equal ["From meta-tags | Dummy"], doc.css("title").map(&:text)
    assert_equal ["App description wins over the site default."], doc.css('meta[name="description"]').map { |m| m["content"] }
  end

  def test_hreflang_and_markdown_alternate
    get "/"
    hreflang = doc.css("link[rel=alternate][hreflang]").to_h { |link| [link["hreflang"], link["href"]] }
    assert_equal({ "en" => "https://www.example.com/", "ko" => "https://www.example.com/?locale=ko",
                   "x-default" => "https://www.example.com/" }, hreflang)
    assert_nil doc.at_css('link[rel=alternate][type="text/markdown"]'), "pages#home does not include Markdownable"
    get "/md_head"
    assert_equal "https://www.example.com/md_head.md", doc.at_css('link[rel=alternate][type="text/markdown"]')["href"]
  end

  def test_markdown_alternate_only_for_markdown_enabled_actions
    get "/plain_head"
    assert_response :success
    assert_nil doc.at_css('link[rel=alternate][type="text/markdown"]'), "excluded by seo_geo_markdown except:"
    get "/md_head"
    href = doc.at_css('link[rel=alternate][type="text/markdown"]')["href"]
    get URI(href).path
    assert_response :success
    assert_equal "text/markdown", response.media_type
  end

  def test_unsupported_md_url_is_a_clean_406
    get "/index.md"
    assert_response :not_acceptable
    assert_equal "text/plain", response.media_type
    get "/plain_head.md"
    assert_response :not_acceptable
  end

  def test_indexable_by_default_and_noindex_outside_production
    get "/"
    assert_nil doc.at_css('meta[name="robots"]')
    with_config(environment: "staging") do
      get "/head_pages/indexed"
      assert_equal "noindex, nofollow", doc.at_css('meta[name="robots"]')["content"]
      assert_nil doc.at_css('link[rel=alternate][type="text/markdown"]')
    end
  end

  def test_unknown_host_is_noindex
    host! "evil.test"
    get "/"
    assert_includes doc.at_css('meta[name="robots"]')["content"], "noindex"
    assert_equal "https://www.example.com/", doc.at_css('link[rel="canonical"]')["href"]
  end

  def test_controller_noindex_and_default_noindex_opt_in
    get "/head_pages/noindex"
    assert_equal "noindex", doc.at_css('meta[name="robots"]')["content"]
    with_config(default_noindex: true) do
      get "/"
      assert_equal "noindex", doc.at_css('meta[name="robots"]')["content"]
      get "/head_pages/indexed"
      assert_nil doc.at_css('meta[name="robots"]')
      assert_equal "https://www.example.com/indexed", doc.at_css('link[rel="canonical"]')["href"]
    end
  end

  def test_canonical_false
    get "/head_pages/no_canonical"
    assert_nil doc.at_css('link[rel="canonical"]')
    assert_empty doc.css("link[rel=alternate][hreflang]")
  end

  def test_verification_metas
    SeoGeo.config.verification.google = "g-token"
    SeoGeo.config.verification.bing = "b-token"
    get "/"
    assert_equal "g-token", doc.at_css('meta[name="google-site-verification"]')["content"]
    assert_equal "b-token", doc.at_css('meta[name="msvalidate.01"]')["content"]
  ensure
    SeoGeo.config.verification.google = nil
    SeoGeo.config.verification.bing = nil
  end

  def test_open_graph_image_and_description_truncation
    SeoGeo.config.og_image.enabled = true # /og/post.png is a gem-rendered image => og_image.width x height
    get "/head_pages/custom"
    assert_equal "https://www.example.com/og/post.png", doc.at_css('meta[property="og:image"]')["content"]
    assert_equal "1200", doc.at_css('meta[property="og:image:width"]')["content"]
    assert_equal "630", doc.at_css('meta[property="og:image:height"]')["content"]
    assert_equal "summary_large_image", doc.at_css('meta[name="twitter:card"]')["content"]
    assert_equal "article", doc.at_css('meta[property="og:type"]')["content"]
    assert_operator doc.at_css('meta[name="description"]')["content"].length, :<=, 160
  ensure
    SeoGeo.config.og_image.enabled = nil
  end

  # extra crawler-visible HTML at the end of the fallback <main>, from a block or content_for.
  def test_fallback_body_extra_slot
    html = ApplicationController.render(inline: <<~ERB)
      <% content_for :seo_geo_fallback_extra, tag.p("from content_for") %>
      <%= seo_geo_fallback_body(:home) do %><p>from block</p><% end %>
    ERB
    main = Nokogiri::HTML(html).at_css("main[data-seo-fallback]")
    assert_equal ["from block", "from content_for"], main.css("p").to_a.last(2).map(&:text)
  end

  def test_json_ld_parses_and_faq_equals_visible_faq
    get "/"
    types = graph.map { |node| node["@type"] }
    assert_equal %w[WebSite Organization FAQPage], types
    faq = graph.find { |node| node["@type"] == "FAQPage" }
    ld_pairs = faq["mainEntity"].map { |q| [q["name"], q.dig("acceptedAnswer", "text")] }
    visible = doc.css("[data-seo-geo-faq-item]").map { |item| [item.at_css("h3").text, item.at_css("p").text] }
    assert_equal [["Is this real?", "It is a test fixture."]], ld_pairs
    assert_equal ld_pairs, visible
  end

  def test_crawler_fallback_body_and_hide_snippet
    get "/"
    head_scripts = doc.css("head script:not([type])").map(&:text).join
    assert_includes head_scripts, "w.SeoGeo.mounted=function()"
    assert_includes head_scripts, "5000"
    assert_includes doc.at_css("head style").text, ".seo-geo-js [data-seo-fallback]{display:none}"
    if inertia_dummy?
      fallback = doc.at_css("main[data-seo-fallback]")
      assert_equal "Welcome to Dummy", fallback.at_css("h1").text
      assert_equal "Fast — Boots in a second.", fallback.at_css("[data-seo-geo-features] li").text.strip
      assert_empty doc.at_css("#app").children
      props = JSON.parse(doc.at_css("#app")["data-page"]).dig("props", "seo")
      assert_equal props["faq"].map { |item| [item["question"], item["answer"]] },
                   fallback.css("[data-seo-geo-faq-item]").map { |item| [item.at_css("h3").text, item.at_css("p").text] }
    else
      assert_nil doc.at_css("[data-seo-fallback]"), "ERB pages render their own body"
    end
  end

  def test_script_content_is_escaped
    get "/head_pages/custom"
    refute_includes response.body, "</script><script>alert(1)"
    thing = graph.find { |node| node["name"].to_s.start_with?("evil") }
    assert_equal "evil </script><script>alert(1)</script>", thing["name"]
    assert_equal "Post </script><b> | Dummy", doc.at_css("title").text
    assert_includes graph.map { |node| node["name"] }, "from view"
    extra = doc.css('script[type="application/ld+json"]').map { |script| JSON.parse(script.text) }.find { |json| json["@type"] == "Event" }
    assert_equal "extra", extra["name"]
  end

  def test_csp_nonce_on_inline_scripts
    get "/head_pages/nonce"
    nonces = doc.css("head script, head style").map { |tag| tag["nonce"] }
    assert_equal 3, nonces.size
    assert_equal ["test-nonce"], nonces.uniq
    get "/"
    assert_empty doc.css("head script[nonce]")
  end
end
