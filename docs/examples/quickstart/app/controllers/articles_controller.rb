# app/controllers/articles_controller.rb
class ArticlesController < ApplicationController
  def show
    seo title: "Example launch", type: "article",
        published_time: Time.iso8601("2026-10-01T09:00:00+09:00"),
        modified_time: "2026-10-02T12:00:00+09:00"
  end
end
