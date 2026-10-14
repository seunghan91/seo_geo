# frozen_string_literal: true

# Markdown negotiation fixture (server-rendered HTML).
class MarkdownPagesController < ApplicationController
  include SeoGeo::Markdownable
  seo_geo_markdown except: %i[plain plain_head]
  layout "markdown_demo"

  def show; end

  def hidden
    @noindex = true
    render :show
  end

  # robots "none" plus an app-set X-Robots-Tag that the Markdown response must keep.
  def robots_none
    @robots = "none"
    response.headers["X-Robots-Tag"] = "googlebot: noarchive"
    render :show
  end

  # Global noindex in the HTML plus a googlebot-scoped header.
  def scoped_header
    @noindex = true
    response.headers["X-Robots-Tag"] = "googlebot: nofollow, noindex"
    render :show
  end

  def plain
    render :show
  end

  # seo_geo_head advertises the Markdown alternate only for markdownable actions.
  def md_head
    render :show, layout: "application"
  end

  def plain_head
    render :show, layout: "application"
  end
end
