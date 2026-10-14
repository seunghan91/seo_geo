# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class AuditChecksTest < Minitest::Test
  FAQ = { "@context" => "https://schema.org", "@graph" => [
    { "@type" => "FAQPage", "mainEntity" => [
      { "@type" => "Question", "name" => "Is it free?", "acceptedAnswer" => { "@type" => "Answer", "text" => "Yes, <b>always</b>." } }
    ] }
  ] }.freeze

  def html(head: "<title>Home</title>", body: "", lang: "en", json_ld: FAQ)
    script = json_ld ? %(<script type="application/ld+json">#{JSON.generate(json_ld).gsub("</", "<\\/")}</script>) : ""
    %(<!DOCTYPE html><html#{%( lang="#{lang}") if lang}><head>#{head}#{script}</head><body>#{body}</body></html>)
  end

  def doc(**options)
    SeoGeo::Audit::HtmlDocument.new(html(**options))
  end

  def test_document_reads_head_values
    page = doc(head: '<title> Home </title><meta name="description" content="D"><link rel="canonical" href="https://x.test/">' \
                     '<meta name="robots" content="NOINDEX, follow"><link rel="alternate" type="text/markdown" href="/index.md">')
    assert_equal ["Home"], page.titles
    assert_equal "D", page.description
    assert_equal "https://x.test/", page.canonical
    assert page.noindex?
    assert_equal "/index.md", page.markdown_alternate
    assert_equal "en", page.html_lang
    assert_nil doc(lang: nil).html_lang
  end

  def test_title_count_ignores_svg_titles
    assert_empty SeoGeo::Audit::Checks.title_count(doc(body: "<svg><title>icon</title></svg>"))
    assert_equal ["2 <title> elements (exactly one expected)"],
                 SeoGeo::Audit::Checks.title_count(doc(head: "<title>a</title><title>b</title>"))
    assert_equal ["no <title>"], SeoGeo::Audit::Checks.title_count(doc(head: ""))
  end

  def test_faq_must_be_visible_and_scripts_do_not_count
    assert_equal 2, SeoGeo::Audit::Checks.faq_visible(doc(body: "<p>nothing</p>")).size
    assert_empty SeoGeo::Audit::Checks.faq_visible(doc(body: "<h3>Is it   free?</h3><p>Yes, &lt;b&gt;always&lt;/b&gt;.</p>"))
    hidden = doc(body: "<script>var q='Is it free? Yes, <b>always</b>.'</script>")
    assert_equal 2, SeoGeo::Audit::Checks.faq_visible(hidden).size
  end

  def test_json_ld_parse_and_required_properties
    broken = SeoGeo::Audit::HtmlDocument.new('<html><head><script type="application/ld+json">{"a":</script></head></html>')
    assert_match(/does not parse/, SeoGeo::Audit::Checks.json_ld(broken).first)
    missing = doc(json_ld: { "@type" => "Organization", "@id" => "#org", "name" => "X" })
    assert_equal ["Organization #org is missing url"], SeoGeo::Audit::Checks.json_ld(missing)
    assert_empty SeoGeo::Audit::Checks.json_ld(doc)
  end

  def test_sitemap_check
    ok = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://www.example.com/</loc></url></urlset>
    XML
    problems, locs, kind = SeoGeo::Audit::Checks.sitemap(ok, origin: "https://www.example.com/")
    assert_empty problems
    assert_equal ["https://www.example.com/"], locs
    assert_equal :urlset, kind
    assert_match(/not under/, SeoGeo::Audit::Checks.sitemap(ok, origin: "https://start.example.com/").first.first)
    evil = ok.sub("https://www.example.com/", "https://www.example.com.evil.test/x")
    assert_match(/not under/, SeoGeo::Audit::Checks.sitemap(evil, origin: "https://www.example.com/").first.first)
    assert_match(/well-formed/, SeoGeo::Audit::Checks.sitemap("<urlset>").first.first)
    assert_match(/root element/, SeoGeo::Audit::Checks.sitemap("<urlset/>").first.first)
  end

  def test_canonical_origin
    assert_empty SeoGeo::Audit::Checks.canonical_origin("https://www.example.com/a", "https://www.example.com")
    assert_equal ["canonical https://example.com/a is not on https://www.example.com"],
                 SeoGeo::Audit::Checks.canonical_origin("https://example.com/a", "https://www.example.com")
    assert_equal ["no <link rel=\"canonical\">"], SeoGeo::Audit::Checks.canonical_origin(nil, "https://www.example.com")
  end

  def test_static_scan_flags_shadowing_files_and_user_agent_branches
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "public"))
      FileUtils.mkdir_p(File.join(root, "app/controllers"))
      File.write(File.join(root, "public/robots.txt"), "User-agent: *\n")
      File.write(File.join(root, "app/controllers/feed_controller.rb"), <<~RUBY)
        class FeedController
          def show
            logger.info(request.user_agent)
            return head(:forbidden) unless request.user_agent.to_s.include?("Googlebot")
            premium = true if request.headers["User-Agent"] =~ /GPTBot/
            # if request.user_agent  (comment only)
          end
        end
      RUBY
      report = SeoGeo::Audit::StaticScan.new(root).call(SeoGeo::Audit::Report.new)
      assert_equal ["public/robots.txt"], report.errors.map(&:url)
      assert_equal %w[app/controllers/feed_controller.rb:4 app/controllers/feed_controller.rb:5], report.warnings.map(&:url)
    end
  end

  def test_report_formats
    report = SeoGeo::Audit::Report.new
    report.add(:warning, "title.length", "long", host: "h", url: "/a")
    refute report.errors?
    report.add(:error, "canonical", "missing", host: "h", url: "/b")
    report.stats["pages"] += 2
    assert report.errors?
    text = report.to_s
    assert text.lines.first.start_with?("ERROR")
    assert_includes text, "1 error(s), 1 warning(s) (2 pages)"
    json = JSON.parse(report.to_json)
    assert_equal 1, json["errors"]
    assert_equal %w[title.length canonical], json["findings"].map { |item| item["check"] }
    assert_raises(ArgumentError) { report.add(:info, "x", "y") }
  end
end
