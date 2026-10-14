# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "i18n"

class PageTest < Minitest::Test
  def setup
    SeoGeo.reset!
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = %i[en ko]
    I18n.locale = :en
  end

  def test_ruby_hash_source_with_aliases
    SeoGeo.pages.register(:pricing, title: "Pricing", heading: "Plans", features: ["Cheap", { name: "Fast", body: "Very" }],
                                    faq: [{ q: "Free?", a: "Yes" }], hero_image: "/hero.png")
    page = SeoGeo.page(:pricing)
    assert_equal "Pricing", page.title
    assert_equal [{ title: "Cheap", description: nil }, { title: "Fast", description: "Very" }], page.features
    assert_equal [{ question: "Free?", answer: "Yes" }], page.faq
    assert_equal "/hero.png", page.props[:hero_image]
    assert_equal :pricing, page.props[:key]
    assert page.frozen?
  end

  def test_yaml_source_localized_with_fallback
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "home.yml"), <<~YAML)
        en:
          title: Home
          faq:
            - question: Why?
              answer: Because.
        ko:
          title: 홈
      YAML
      File.write(File.join(dir, "flat.yml"), "title: Flat\n")
      SeoGeo.pages.paths = [dir]
      assert_equal "Home", SeoGeo.page(:home).title
      assert_equal "홈", SeoGeo.page(:home, locale: :ko).title
      assert_equal "Home", SeoGeo.page(:home, locale: :ja).title, "falls back to site.default_locale"
      assert_equal "Flat", SeoGeo.page(:flat, locale: :ko).title
      assert_equal %i[flat home], SeoGeo.pages.keys.sort
    end
  end

  def test_i18n_numbered_faq
    I18n.backend.store_translations(:en, views: { login: { seo: { title: "Log in", q1_q: "One?", q1_a: "1", q2_q: "Two?", q2_a: "2" } } })
    SeoGeo.pages.register_i18n(:login, scope: "views.login.seo", faq: :numbered)
    page = SeoGeo.page(:login)
    assert_equal "Log in", page.title
    assert_equal [{ question: "One?", answer: "1" }, { question: "Two?", answer: "2" }], page.faq
    refute page.extra.key?(:q1_q)
  end

  def test_missing_page
    error = assert_raises(KeyError) { SeoGeo.page(:nope) }
    assert_includes error.message, ":nope"
  end

  def test_to_markdown
    SeoGeo.pages.register(:home, heading: "Hello", intro: "Intro.", features: [{ title: "A", description: "a" }],
                                 faq: [{ q: "Q?", a: "A." }])
    assert_equal "# Hello\n\nIntro.\n\n## Features\n\n- **A**: a\n\n## FAQ\n\n### Q?\n\nA.\n", SeoGeo.page(:home).to_markdown
  end

  def test_registered_data_is_isolated_from_source_callers_and_other_requests
    source = { title: +"Demo", faq: [{ q: +"Q?", a: +"A." }], tags: [+"x"] }
    SeoGeo.pages.register(:demo, source)
    source[:title] << " mutated"
    source[:faq].first[:q] << " mutated"
    assert_equal "Demo", SeoGeo.page(:demo).title

    page = SeoGeo.page(:demo)
    assert page.title.frozen?
    assert page.faq.first[:question].frozen?
    assert_raises(FrozenError) { page.extra[:tags].first << "y" }

    props = page.props
    props[:title].replace("Request-specific")
    props[:faq].first[:question] << "!"
    props[:tags] << "z"
    fresh = SeoGeo.page(:demo)
    assert_equal "Demo", fresh.title
    assert_equal "Q?", fresh.faq.first[:question]
    assert_equal ["x"], fresh.props[:tags]
    refute props[:title].frozen?, "props is a mutable copy"
  end
end
