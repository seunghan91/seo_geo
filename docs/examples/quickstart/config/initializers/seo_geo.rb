# config/initializers/seo_geo.rb
SeoGeo.configure do |seo|
  seo.site.name = "Example"
  seo.site.description = "Example helps small teams plan their week."
  seo.canonical_origin = "https://www.example.com"
  seo.canonical_aliases = ["example.com"]           # folded onto www.example.com
  seo.host "www.example.com", disallow: ["/admin"]  # every crawler group repeats this
  seo.crawlers.training = :deny                     # GPTBot, ClaudeBot, CCBot, ... => Disallow: /
end

SeoGeo.sitemap.draw do
  add "/", priority: 1.0
  add "/pricing"
end

SeoGeo.config.llms_txt.page :home, path: "/"
