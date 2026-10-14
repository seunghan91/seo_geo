# frozen_string_literal: true

# Mimics inertia_rails: the server sends an empty mount point plus JSON props; the client renders.
class PagesController < ApplicationController
  def home
    @inertia_page = { component: "Home", props: { seo: seo_geo_page(:home).props }, url: request.path }
    render html: "", layout: "application"
  end
end
