# frozen_string_literal: true

# audit, test helpers fixtures; shared verbatim by both dummies.
class AuditPagesController < ApplicationController
  include SeoGeo::Markdownable
  seo_geo_markdown only: :markdown

  before_action { @inertia_page = { component: "AuditPages", props: {}, url: request.path } }

  def markdown
    seo title: "Markdown page", description: "A fixture page that also serves Markdown to agents through Accept negotiation."
    render html: "<main><h1>Markdown page</h1><p>Body text.</p></main>".html_safe, layout: "application"
  end

  # FAQPage JSON-LD whose text is not on the page (the audit and the FAQ assertion must catch it).
  def hidden_faq
    seo title: "Hidden FAQ", description: "A fixture page whose FAQ structured data is missing from the visible text.",
        json_ld: { "@type" => "FAQPage", "@id" => "https://www.example.com/audit_pages/hidden_faq#faq",
                   "mainEntity" => [{ "@type" => "Question", "name" => "Secret question?",
                                      "acceptedAnswer" => { "@type" => "Answer", "text" => "Never shown." } }] }
    render html: "<p>No FAQ here.</p>".html_safe, layout: "application"
  end
end
