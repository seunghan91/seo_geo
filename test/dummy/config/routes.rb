# frozen_string_literal: true

Rails.application.routes.draw do
  mount SeoGeo::Engine, at: "/"
  root "pages#home"

  # head / JSON-LD / fallback test actions
  %w[custom noindex indexed no_canonical nonce app_title].each { |name| get "/head_pages/#{name}", to: "head_pages##{name}" }
  # Markdown negotiation fixtures
  get "/guide(.:format)", to: "markdown_pages#show"
  get "/hidden(.:format)", to: "markdown_pages#hidden"
  get "/plain(.:format)", to: "markdown_pages#plain"
  get "/robots_none(.:format)", to: "markdown_pages#robots_none"
  get "/scoped_header(.:format)", to: "markdown_pages#scoped_header"
  get "/docs", to: "markdown_pages#show"
  get "/md_head(.:format)", to: "markdown_pages#md_head"
  get "/plain_head(.:format)", to: "markdown_pages#plain_head"
  # audit / test helper fixtures
  get "/audit_pages/markdown(.:format)", to: "audit_pages#markdown"
  get "/audit_pages/hidden_faq", to: "audit_pages#hidden_faq"
  # The app's own OG route : drawn after the root mount, it must still win for every key
  # seo_geo does not render.
  get "/og/:username.png", format: false, to: lambda { |env|
    name = env["action_dispatch.request.path_parameters"][:username]
    [200, { "content-type" => "text/plain" }, ["app og #{name}"]]
  }
end
