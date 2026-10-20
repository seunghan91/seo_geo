# config/routes.rb
Rails.application.routes.draw do
  root "pages#home"
  get "/pricing", to: "pages#pricing"
  get "/articles/launch", to: "articles#show"

  mount SeoGeo::Engine, at: "/"  # last, so your own routes win where paths overlap
end
