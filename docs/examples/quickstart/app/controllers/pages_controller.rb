# app/controllers/pages_controller.rb
class PagesController < ApplicationController
  include SeoGeo::Markdownable  # Accept: text/markdown and /pricing.md

  def home
    @page = seo_geo_page(:home)  # title, description and FAQPage JSON-LD from home.yml
  end

  def pricing
    seo title: "Pricing", description: "Free for up to three people; paid plans for larger teams, billed monthly."
  end
end
