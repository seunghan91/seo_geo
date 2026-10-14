# frozen_string_literal: true

SeoGeo::Engine.routes.draw do
  # robots, sitemap, llms.txt
  get "/robots.txt", to: "robots#show", format: false
  get "/sitemap.xml", to: "sitemaps#show", format: false
  get "/sitemap-:page.xml", to: "sitemaps#show", format: false, constraints: { page: /[1-9][0-9]*/ }
  get "/llms.txt", to: "llms#show", format: false
  get "/llms-full.txt", to: "llms#full", format: false

  # IndexNow key file, OG images
  get "/:indexnow_key.txt", to: "index_now#key", format: false,
                            constraints: SeoGeo::IndexNow::KeyConstraint
  # Matches only when og_image is enabled and the key is known (OgImage::RouteConstraint); anything else falls
  # through to the application's routes (e.g. its own /og/:username.png).
  get "/og/:key.png", to: "og_images#show", format: false, constraints: SeoGeo::OgImage::RouteConstraint
end
