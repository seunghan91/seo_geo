# frozen_string_literal: true

require "test_helper"

class MetaTest < Minitest::Test
  def config
    @config ||= configured(canonical_aliases: ["example.com"], indexable_environments: ["test"], environment: "test") do |c|
      c.site.name = "Example"
      c.site.description = "Site description."
      c.canonical_exclude_hosts = ["store.example.com"]
    end
  end

  def meta(url = "https://www.example.com/", locale: :en, **state)
    SeoGeo::Meta.new(config: config, url: url, locale: locale, state: SeoGeo::Meta::State.new(**state))
  end

  def test_title_precedence_and_single_template
    assert_equal "Post | Example", meta(title: "Post").full_title
    assert_equal "Example", meta.full_title, "site name alone is not repeated"
    page = SeoGeo::Page.from_hash(:home, { title: "Home", description: "Home description." })
    assert_equal "Home | Example", meta(page: page).full_title
    assert_equal "Explicit | Example", meta(page: page, title: "Explicit").full_title
    app = SeoGeo::Meta.new(config: config, url: "https://www.example.com/", app_title: "From app")
    assert_equal "From app | Example", app.full_title
  end

  def test_description_falls_back_and_truncates
    assert_equal "Site description.", meta.description
    long = meta(description: "word " * 100).description
    assert_operator long.length, :<=, 160
    assert long.end_with?("…")
  end

  def test_canonical_folds_alias_host_and_query
    assert_equal "https://www.example.com/pricing", meta("https://example.com/pricing?utm_source=x&gclid=1").canonical
    assert_equal "https://store.example.com/refund", meta("https://store.example.com/refund?x=1").canonical
    assert_equal "https://www.example.com/other", meta("https://example.com/a", canonical: "/other?utm=1").canonical
    assert_nil meta(canonical: false).canonical
  end

  def test_hreflang_and_locale_canonical
    config.locales = %i[en ko]
    alternates = meta("https://example.com/a?utm=1").alternates
    assert_equal [%w[en https://www.example.com/a], %w[ko https://www.example.com/a?locale=ko],
                  %w[x-default https://www.example.com/a]], alternates.map { |link| link.values_at(:hreflang, :href) }
    assert_equal "https://www.example.com/a?locale=ko", meta("https://www.example.com/a", locale: :ko).canonical
    assert_empty meta(canonical: false).alternates
    config.hreflang_url = ->(locale, url) { url.sub("https://www.example.com", "https://www.example.com/#{locale}") }
    assert_equal "https://www.example.com/ko/a", meta("https://www.example.com/a", locale: :ko).canonical
  end

  def test_noindex_rules
    refute meta.noindex?
    assert meta(noindex: true).noindex?
    assert meta("https://unknown.test/").noindex?, "fail-closed host"
    config.environment = "staging"
    assert meta(index: true).noindex?, "non-production wins over index: true"
    assert meta.environment_noindex?
    config.environment = "test"
    config.default_noindex = true
    assert meta.noindex?
    refute meta(index: true).noindex?
    assert meta(index: true, noindex: true).noindex?
  end

  # Head robots meta and sitemap.xml must agree: a path registered with index: true under default_noindex
  # is listed in the sitemap, so its head must not say noindex.
  def test_registry_index_true_overrides_default_noindex_in_head
    config.default_noindex = true
    SeoGeo.sitemap.add "/listed", index: true
    refute meta("https://www.example.com/listed").noindex?
    assert meta("https://www.example.com/other").noindex?
  ensure
    SeoGeo.sitemap.clear if SeoGeo.sitemap.respond_to?(:clear)
  end

  def test_markdown_url
    assert_equal "https://www.example.com/index.md", meta.markdown_url
    assert_equal "https://www.example.com/docs/a.md", meta("https://www.example.com/docs/a").markdown_url
    assert_equal "https://www.example.com/docs/index.md", SeoGeo::Meta.markdown_url_for("https://www.example.com/docs/")
    assert_nil meta(markdown: false).markdown_url
    assert_nil meta(noindex: true).markdown_url
    config.markdown.enabled = false
    assert_nil meta.markdown_url
  end

  def test_markdown_url_requires_a_markdown_enabled_action
    unavailable = ->(**state) { SeoGeo::Meta.new(config: config, url: "https://www.example.com/", state: SeoGeo::Meta::State.new(**state), markdown_available: false) }
    assert_nil unavailable.call.markdown_url
    assert_equal "https://www.example.com/index.md", unavailable.call(markdown: true).markdown_url
  end

  def test_tags_open_graph_twitter_and_verification
    config.verification.google = "g-token"
    config.verification.naver = "n-token"
    tags = meta("https://example.com/x", locale: :"ko-KR", title: "X", image: "/og.png", type: "article").tags
    assert_equal "https://www.example.com/x", tags[:canonical]
    # an app image of unknown size gets no og:image:width/height.
    assert_equal({ _: "https://www.example.com/og.png" }, tags[:og][:image])
    assert_equal "article", tags[:og][:type]
    assert_equal "ko_KR", tags[:og][:locale]
    assert_equal "summary_large_image", tags[:twitter][:card]
    assert_equal "g-token", tags[:"google-site-verification"]
    assert_equal "n-token", tags[:"naver-site-verification"]
    refute tags.key?(:noindex)
    assert_equal "summary", meta.tags[:twitter][:card]
    config.og_image.fallback_url = "https://cdn.example.com/default.png"
    assert_equal "https://cdn.example.com/default.png", meta.image_url
  end

  def test_article_times_accept_time_date_and_iso_strings
    inputs = { Time.new(2026, 10, 20, 12, 30, 0, "+09:00") => "2026-10-20T12:30:00+09:00",
               Date.new(2026, 10, 20) => "2026-10-20",
               DateTime.iso8601("2026-10-20T12:30:00+09:00") => "2026-10-20T12:30:00+09:00",
               "2026-10-20T03:30:00Z" => "2026-10-20T03:30:00Z", "2026-10-20" => "2026-10-20" }
    inputs.each do |input, expected|
      assert_equal({ published_time: expected, modified_time: expected },
                   meta(type: "article", published_time: input, modified_time: input).tags[:article])
    end
    assert_equal({ published_time: "2026-10-20" }, meta(type: "article", published_time: "2026-10-20").tags[:article])
    refute meta(type: "article").tags.key?(:article)
    refute meta(published_time: "bad", modified_time: "bad").tags.key?(:article)
    assert_raises(ArgumentError) { meta(type: "article", published_time: "yesterday").tags }
    assert_raises(ArgumentError) { meta(type: "article", modified_time: 123).tags }
    controller = Class.new { include SeoGeo::Controller }.new
    controller.seo(type: "article", published_time: "2026-10-20")
    assert_equal "2026-10-20", controller.seo_geo_state.published_time
  end

  def test_json_ld_graph_includes_site_page_and_extra_nodes
    page = SeoGeo::Page.from_hash(:home, { faq: [{ q: "Q?", a: "A." }] })
    graph = meta("https://example.com/?utm=1", page: page, json_ld: [{ "@type" => "Thing", "name" => "x" }]).json_ld.to_h["@graph"]
    assert_equal %w[WebSite Organization FAQPage Thing], graph.map { |node| node["@type"] }
    assert_equal "https://www.example.com/#faq", graph[2]["@id"]
  end
end
