# AGENTS.md — seo_geo (Ruby / Rails)

Guidance for AI coding agents that add this gem to an application or work on this repository. Humans: the
[README](README.md) has the same facts with more explanation.

## What this is

A Rails engine for SEO and GEO. GEO is Generative Engine Optimization: visibility in AI search and assistants
(ChatGPT, Claude, Perplexity, Gemini). It is **not** a geolocation, GeoIP or maps gem. One initializer and one
layout line produce the head (title, description, canonical, hreflang, Open Graph, JSON-LD), per-host
`robots.txt`, `sitemap.xml`, `llms.txt`/`llms-full.txt`, Markdown responses for agents, IndexNow pings, OG
images and an audit task.

## When to use it

**Use it when** a Rails 7.2–8.1 app (ERB, Hotwire or Inertia) needs search and AI-crawler visibility managed
in one place: several hostnames folded onto one canonical origin, a crawler policy by purpose (training vs
search vs user-triggered fetch), FAQ copy that must match its JSON-LD, or Inertia/SPA pages that crawlers see as
empty.

**Do not use it when**

- you need geolocation (IP to country, maps) — this gem does not do that;
- the app is not Rails (plain Rack, Sinatra, Hanami) — the engine needs Railties and ActionPack;
- you want to promise rich results or rankings — the gem emits valid markup, nothing more;
- a CDN or framework already owns `/robots.txt`, `/sitemap.xml` and the `<head>`; run one source, not two.

## Integration recipe

1. `bundle add seo_geo`, then `bin/rails g seo_geo:install https://www.example.com`. The generator writes
   `config/initializers/seo_geo.rb` and `config/seo_geo/pages/home.yml`. It mounts the engine as the last
   route, before a top-level catch-all if there is one.
2. Delete `public/robots.txt`, `public/sitemap.xml` and `public/llms.txt` if they exist: static files win over
   the engine routes.
3. Configure hosts, crawler purposes, the sitemap and llms.txt:

<!-- example: quickstart/config/initializers/seo_geo.rb -->
```ruby
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
```

4. Replace the app's `<title>`, meta description, canonical link and JSON-LD with one line. `seo_geo_head`
   emits exactly one `<title>`; remove any other.

<!-- example: quickstart/app/views/layouts/application.html.erb -->
```erb
<%# app/views/layouts/application.html.erb %>
<!DOCTYPE html>
<html lang="<%= seo_geo_html_lang %>">
  <head>
    <meta charset="utf-8">
    <%= seo_geo_head %>
  </head>
  <body>
    <main><%= yield %></main>
  </body>
</html>
```

5. Set per-page values in controllers: `seo title:, description:` for one-off pages, `seo_geo_page(:key)` for
   pages with registered copy. Include `SeoGeo::Markdownable` where agents should get Markdown.

<!-- example: quickstart/app/controllers/pages_controller.rb -->
```ruby
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
```

6. **Inertia** (React/Vue/Svelte): pass `seo_geo_page(:key).props` as a prop and render the visible copy from
   it. In the layout, render `seo_geo_fallback_body(page)` after `yield`. After the client app mounts, call
   `window.SeoGeo?.mounted()`. Use `seo_geo_markdown page: :key` so Markdown comes from the copy rather than the
   empty `#app` div:

<!-- example: inertia/app/controllers/pages_controller.rb -->
```ruby
# app/controllers/pages_controller.rb (inertia_rails)
class PagesController < ApplicationController
  include SeoGeo::Markdownable
  seo_geo_markdown only: :home, page: :home  # Markdown from the page copy, not the empty #app div

  def home
    render inertia: "Home", props: { seo: seo_geo_page(:home).props }
  end
end
```

<!-- example: inertia/app/views/layouts/application.html.erb -->
```erb
<%# app/views/layouts/application.html.erb (Inertia) %>
<!DOCTYPE html>
<html lang="<%= seo_geo_html_lang %>">
  <head>
    <meta charset="utf-8">
    <%= seo_geo_head %>
  </head>
  <body>
    <%= yield %>
    <% if (page = seo_geo_state.page) %>
      <%= seo_geo_fallback_body(page) %>
    <% end %>
  </body>
</html>
```

7. Add integration tests with the gem's assertions. They run the audit's own checks:

<!-- example: quickstart/test/integration/seo_test.rb -->
```ruby
# test/integration/seo_test.rb
require "test_helper"
require "seo_geo/testing"

class SeoTest < ActionDispatch::IntegrationTest
  include SeoGeo::Testing::Assertions

  test "one title and a folded canonical" do
    assert_seo_geo_single_title "/"
    assert_seo_geo_canonical "/pricing", host: "example.com", expected: "https://www.example.com/pricing"
  end

  test "FAQ JSON-LD matches the visible text" do
    assert_seo_geo_faq_matches_visible "/"
  end

  test "production robots.txt and sitemap" do
    with_seo_geo_environment("production") do
      refute_seo_geo_robots_allows "GPTBot", "/", host: "www.example.com"
      assert_seo_geo_robots_allows "OAI-SearchBot", "/pricing", host: "www.example.com"
      refute_seo_geo_robots_allows "OAI-SearchBot", "/admin", host: "www.example.com"
      assert_seo_geo_sitemap host: "www.example.com"
      assert_seo_geo_no_sitemap host: "example.com"
    end
  end
end
```

RSpec: `require "seo_geo/rspec"` gives `have_seo_geo_canonical`, `have_seo_geo_single_title`,
`have_seo_geo_faq_matching_visible_text`, `be_seo_geo_valid_sitemap(origin:)` and `seo_geo_robots_allow(ua, path)`.

For article pages, pass `type: "article"`, `published_time:` and `modified_time:` to `seo`.
Use the article's real stored dates: `Time`, `Date` and ISO 8601 strings are accepted and output as ISO 8601.
Date-only values remain date-only; invalid values raise `ArgumentError` when rendering an article.
These tags are omitted for other OG types and when no time is supplied.

<!-- example: quickstart/app/controllers/articles_controller.rb -->
```ruby
# app/controllers/articles_controller.rb
class ArticlesController < ApplicationController
  def show
    seo title: "Example launch", type: "article",
        published_time: Time.iso8601("2026-10-01T09:00:00+09:00"),
        modified_time: "2026-10-02T12:00:00+09:00"
  end
end
```

<!-- output: quickstart GET /articles/launch Host=www.example.com -->
```html
<meta property="article:published_time" content="2026-10-01T09:00:00+09:00">
<meta property="article:modified_time" content="2026-10-02T12:00:00+09:00">
```

## Invariants — do not violate

1. **Hosts fail closed.** Every hostname that serves the app is either `canonical_origin`'s host, listed in
   `canonical_aliases`/`canonical_exclude_hosts`, or declared with `seo.host`. Undeclared hosts (staging,
   `*.onrender.com`) get `Disallow: /` and no sitemap. Never "fix" a closed host by allowing everything.
2. **One copy source per page.** Text that appears in FAQPage JSON-LD comes from `SeoGeo.page(:key)` and is
   rendered from the same object (`seo_geo_faq`, `seo_geo_fallback_body`, `Page#props`). Never hand-write a
   second copy in a view or component, and never add JSON-LD for content that is not visible.
3. **The User-Agent is not identity.** Do not branch access, content or rate limits on `request.user_agent`
   (`rake seo_geo:audit` warns: `code.user_agent_branch`). To trust a bot, add
   `config.middleware.use SeoGeo::BotVerifier::Middleware` and require `request.env["seo_geo.bot"][:verified] == true`.
4. **Never invent `lastmod`.** No `Time.now`, `Date.today` or `updated_at` of an unrelated record. Use a real
   column (`lastmod: :updated_at`) or omit it. No made-up prices, ratings or counts in JSON-LD either.
5. **Noindex in one place.** A page that must stay out of search goes in `noindex_paths` or
   `sitemap.add path, noindex: true`, which keeps it out of sitemap.xml and llms.txt and renders robots
   noindex. A request-time `seo noindex: true` alone cannot reach sitemap.xml.
6. **Mount last.** `mount SeoGeo::Engine, at: "/"` stays below the app's routes and above any catch-all.
7. **`:full_access` is opt-in.** `crawlers.override "Mediapartners-Google", :full_access` ignores every host
   `disallow` for that token. Never use it for AI crawlers or as a way to open a path; use `allow:` instead.
8. **Collections are lambdas.** `add -> { Post.published }, path: ...`. A scope passed directly loads the model
   at boot and keeps a stale class across development reloads. `select` must include `id` (records are read
   with `find_each`).

## Check commands

```sh
bundle exec rake test                    # this repository: unit, docs examples, both dummy apps
bin/rails seo_geo:audit                  # your app: exits 1 on errors; FORMAT=json HOSTS=a,b MAX_PAGES=200
SEO_GEO_AUDIT=1 bin/rails runner 'puts SeoGeo::Audit::Runner.new(app: Rails.application, root: Rails.root).run'
```

The rake task audits as production even in development: it sets `SEO_GEO_AUDIT=1` itself, so the engine adds
the configured hosts to `config.hosts` for that run (`seo_geo audit: temporarily allowing ... in config.hosts`).
A runner needs the variable before boot. Production `config.hosts` is never widened.

Audit deployed HTTP responses without booting the application with `URL` or comma-separated `URLS`:

```sh
bundle exec rake seo_geo:audit URL=https://www.example.com
bundle exec rake seo_geo:audit URLS=https://www.example.com,https://www.example.com/pricing FORMAT=json
```

Remote requests run serially with a 0.5-second pause between requests, 10-second connect/read/write timeouts
and `User-Agent: seo_geo-audit/<VERSION>`. The initial response remains the audit input; redirect destinations
are explicitly probed and recorded up to five hops. More than one hop warns (`page.redirect_chain`), while loops,
unfinished chains and `X-Robots-Tag: noindex` (including scoped `none`) are errors. `robots.mismatch` warns only
when an already available configuration declares the host and its rendered robots.txt differs from the response.
No Rails initializer is loaded for remote mode, so pass an existing configuration via
`SeoGeo::Audit::Remote.run(urls, io: $stdout, config: config)` when a comparison is needed.
Without configuration, canonical URLs are checked against the requested origin and robots blocking against `*`;
intentional crawler-specific denials cannot be inferred. Both audit modes probe a random missing path per host
(`page.soft_404` on 2xx) and warn about duplicate descriptions on indexable pages (`description.duplicate`).
Remote audits judge the live site as production would: like the in-process audit they switch the config to an indexable environment for the run and restore it afterwards. They do not widen `config.hosts` or scan local source files.

With the app running (`bin/rails s`), check what crawlers and agents receive. robots.txt and sitemap.xml only
open up in `indexable_environments` (default production):

<!-- curl: quickstart -->
```sh
curl -s -H "Host: www.example.com" http://localhost:3000/robots.txt
curl -s -H "Host: unknown.example.net" http://localhost:3000/robots.txt     # Disallow: /
curl -s -H "Host: www.example.com" http://localhost:3000/sitemap.xml
curl -s -H "Host: example.com" http://localhost:3000/sitemap.xml           # => 404 (alias)
curl -s -H "Host: www.example.com" http://localhost:3000/llms.txt
curl -si -H "Host: www.example.com" -H "Accept: text/markdown" http://localhost:3000/pricing
curl -si -H "Host: www.example.com" http://localhost:3000/index.md
```

## Troubleshooting

See the README's [Troubleshooting](README.md#troubleshooting) table (exact error messages, causes and fixes).

## Working on this repository

- Verify with `bundle exec rake test`: unit tests, docs examples, then app tests against `test/dummy` (ERB)
  and `test/dummy_inertia`, each dummy in its own process. Other Rails versions:
  `BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rake test` (also `rails_8_0`, `rails_8_1`).
- [docs/DESIGN.md](docs/DESIGN.md) is the contract. Names and signatures in § Public API and § Shared contract
  are fixed; changing one means updating DESIGN.md in the same change. New configuration keys get a default, a
  YARD comment, an `errors` entry when they can be invalid, and a test in `test/unit/configuration_test.rb`.
- Shared files have append-only zones: `lib/seo_geo.rb` (require list), `lib/seo_geo/engine.rb` (one named
  initializer per topic), `config/routes.rb` and `CHANGELOG.md` (one bullet per change under Unreleased).
- Reuse the shared primitives instead of re-implementing them: `SeoGeo::RobotsPath` (RFC 9309 path
  normalization), `SeoGeo::RobotsDirectives`, `SeoGeo::SafeRegexp`, `SeoGeo::Publication.publishable?`, and
  `config.canonical_url` / `config.host_policy`.
- Tests: `test/unit/**` boots no Rails app; `test/app/**` runs against both dummies (`inertia_dummy?` to branch);
  `test/docs/**` boots `docs/examples/` apps in subprocesses and checks README/AGENTS code blocks against them.
  A README or AGENTS code block in Ruby, ERB, YAML or JS needs a `<!-- example: path -->` marker and a file
  under `docs/examples/`; output blocks use `<!-- output: ... -->` and are compared with real responses.
- Every Ruby file under `lib/` and `app/` starts with `# frozen_string_literal: true`; public methods carry YARD
  comments.

## Related packages

- [meta-tags](https://github.com/kpumuk/meta-tags): the tag renderer seo_geo builds on; `set_meta_tags` values
  still apply.
- [inertia_rails](https://github.com/inertiajs/inertia-rails): pair with `Page#props` and `seo_geo_fallback_body`.
- [webmcp](https://github.com/seunghan91/webmcp): lets in-browser AI agents call your app's endpoints as tools.
  It complements seo_geo, which is about being read rather than being operated.
