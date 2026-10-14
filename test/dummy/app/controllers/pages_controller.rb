# frozen_string_literal: true

class PagesController < ApplicationController
  def home
    @page = seo_geo_page(:home)
  end
end
