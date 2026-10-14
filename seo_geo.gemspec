# frozen_string_literal: true

require_relative "lib/seo_geo/version"

Gem::Specification.new do |spec|
  spec.name = "seo_geo"
  spec.version = SeoGeo::VERSION
  spec.authors = ["seunghan Kim"]
  spec.email = ["theqwe2000@gmail.com"]
  spec.summary = "SEO and GEO (AI search visibility) for Rails: meta, JSON-LD, robots, sitemap, llms.txt, Markdown"
  spec.description = "A Rails engine that replaces per-app SEO/GEO code with one configuration file and one " \
                     "layout line: meta tags, canonical folding, JSON-LD, crawler fallback bodies, purpose-based " \
                     "AI crawler policy, robots.txt, sitemap.xml, llms.txt, Markdown negotiation, IndexNow and " \
                     "OG images. GEO means Generative Engine Optimization, not geolocation."
  spec.homepage = "https://github.com/seunghan91/seo_geo"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*",
                   "README.md", "CHANGELOG.md", "LICENSE.txt", "llms.txt", "AGENTS.md"].select { |path| File.file?(path) }
  spec.require_paths = ["lib"]
  spec.metadata["changelog_uri"] = "https://github.com/seunghan91/seo_geo/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/seunghan91/seo_geo/issues"
  spec.metadata["documentation_uri"] = "https://github.com/seunghan91/seo_geo#readme"
  spec.metadata["source_code_uri"] = "https://github.com/seunghan91/seo_geo"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.add_dependency "railties", ">= 7.2", "< 9"
  spec.add_dependency "actionpack", ">= 7.2", "< 9"
  spec.add_dependency "meta-tags", "~> 2.24"
  spec.add_dependency "reverse_markdown", "~> 3.0"
  spec.add_development_dependency "activejob", ">= 7.2", "< 9"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
