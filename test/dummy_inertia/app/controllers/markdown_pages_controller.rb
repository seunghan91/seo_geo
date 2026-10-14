# frozen_string_literal: true

# Markdown negotiation for a client-rendered page; the copy comes from SeoGeo.page(:home).
class MarkdownPagesController < ApplicationController
  include SeoGeo::Markdownable
  seo_geo_markdown except: %i[plain plain_head], page: :home
  layout "markdown_demo"

  def show
    render html: "", layout: "markdown_demo"
  end

  def hidden
    show
  end

  def plain
    show
  end

  # seo_geo_head advertises the Markdown alternate only for markdownable actions.
  def md_head
    @inertia_page = { component: "Guide", props: {}, url: request.path }
    render html: "", layout: "application"
  end

  def plain_head
    md_head
  end
end
