# config/routes.rb
Rails.application.routes.draw do
  root "pages#home"
  get "/pricing", to: "pages#pricing"

  mount SeoGeo::Engine, at: "/"  # last, so your own routes win where paths overlap
end
