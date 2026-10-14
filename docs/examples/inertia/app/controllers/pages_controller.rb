# app/controllers/pages_controller.rb (inertia_rails)
class PagesController < ApplicationController
  include SeoGeo::Markdownable
  seo_geo_markdown only: :home, page: :home  # Markdown from the page copy, not the empty #app div

  def home
    render inertia: "Home", props: { seo: seo_geo_page(:home).props }
  end
end
