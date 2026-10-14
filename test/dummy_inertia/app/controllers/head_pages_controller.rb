# frozen_string_literal: true

# head, JSON-LD, crawler fallback test actions; shared verbatim by both dummies.
class HeadPagesController < ApplicationController
  before_action { @inertia_page = { component: "HeadPages", props: {}, url: request.path } }

  def custom
    seo title: "Post </script><b>", description: "Word " * 60, image: "/og/post.png", type: "article",
        json_ld: { "@type" => "Thing", "name" => "evil </script><script>alert(1)</script>" }
    render inline: <<~ERB, layout: "application"
      <% seo_geo_json_ld({ "@type" => "Thing", "@id" => "https://www.example.com/x#view", "name" => "from view" }) %>
      <% content_for :seo_geo_json_ld, seo_geo_json_ld_tag({ "@context" => "https://schema.org", "@type" => "Event", "name" => "extra" }) %>
      <p>custom</p>
    ERB
  end

  def noindex
    seo noindex: true
    render html: "<p>noindex</p>".html_safe, layout: "application"
  end

  def indexed
    seo index: true, canonical: "/indexed?utm_source=x"
    render html: "<p>indexed</p>".html_safe, layout: "application"
  end

  def no_canonical
    seo canonical: false
    render html: "<p>no canonical</p>".html_safe, layout: "application"
  end

  def nonce
    request.content_security_policy_nonce_generator = ->(_request) { "test-nonce" }
    render html: "<p>nonce</p>".html_safe, layout: "application"
  end

  def app_title
    set_meta_tags title: "From meta-tags", description: "App description wins over the site default."
    render html: "<p>app</p>".html_safe, layout: "application"
  end
end
