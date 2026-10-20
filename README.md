# seo_geo

[![Gem Version](https://img.shields.io/gem/v/seo_geo)](https://rubygems.org/gems/seo_geo) [![CI](https://github.com/seunghan91/seo_geo/actions/workflows/ci.yml/badge.svg)](https://github.com/seunghan91/seo_geo/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

SEO and GEO for Rails in one engine: one initializer and one layout line.

seo_geo handles **SEO** (search engines) and **GEO**, *Generative Engine Optimization*: being found,
read and quoted by AI search and assistants such as ChatGPT, Claude, Perplexity and Gemini. It is **not** a
geolocation, GeoIP or maps library.

Rails apps usually rewrite the same SEO code by hand, and the copies drift apart. seo_geo replaces that code
with one configuration file. It renders the head (title, description, canonical URL, hreflang, Open
Graph, JSON-LD). It serves `robots.txt`, `sitemap.xml` and `llms.txt` per host, and Markdown versions of
your pages for agents. It notifies IndexNow and audits the result. All of this follows one crawler policy
and one copy source per page, so the FAQ a crawler reads in JSON-LD is the FAQ a person sees.

## Features

- **Head in one line** — `<%= seo_geo_head %>` emits exactly one `<title>` (through `title_template`), a
  truncated meta description, a canonical URL folded onto `canonical_origin`, hreflang + `x-default`, robots
  `noindex` outside production, search-console verification metas, Open Graph/Twitter tags, a
  `<link rel="alternate" type="text/markdown">` and a JSON-LD `@graph` (CSP nonce aware). `seo_geo_html_lang`
  fills `<html lang>`.
- **Per-request values** — `seo title:, description:, image:, noindex:, index:, canonical:, type:, json_ld:` in
  controllers; `SeoGeo::JsonLd` checks the properties Google requires for each type.
- **One copy source per page** — `SeoGeo.page(:home)` / `seo_geo_page(:home)` reads
  `config/seo_geo/pages/*.yml`, I18n or Ruby. The same copy feeds the head, the FAQPage JSON-LD, the visible
  FAQ (`seo_geo_faq`) and Inertia props (`Page#props`).
- **Crawler fallback body** — `seo_geo_fallback_body(:home)` renders that copy as static HTML for crawlers that
  do not run JavaScript on Inertia/SPA pages; `window.SeoGeo.mounted()` hides it for people.
- **Purpose-based crawler policy** — `crawlers.training`, `crawlers.search` and `crawlers.user` (user-triggered
  fetches such as ChatGPT-User) are `:allow` or `:deny`. That one policy drives the robots.txt groups and the
  `Content-Signal` line and header, plus AIPREF `Content-Usage` (experimental).
- **`GET /robots.txt` per host** — RFC 9309 groups that repeat every host `Disallow`. Undeclared hosts
  fail closed (`Disallow: /`), and so do non-production environments.
- **`GET /sitemap.xml`** — static paths and lazy collections (`add -> { Post.published }, path: ...`), a
  sitemap index above 50,000 URLs, never an invented `lastmod`.
- **`GET /llms.txt` and `/llms-full.txt`** — generated from the page copy and the sitemap. Both use the same
  publication rule as sitemap.xml, so robots-blocked and noindex pages stay out.
- **Markdown for agents** — `include SeoGeo::Markdownable` answers `Accept: text/markdown` and `/page.md` URLs
  with YAML frontmatter, the main content and JSON-LD, plus `Vary: Accept`.
- **IndexNow** — `SeoGeo::IndexNow.submit(urls)`, `SeoGeo::IndexNowJob` with retries, the model macro
  `seo_geo_indexnow on: :publish, url: ->(post) { post_url(post) }`, and the key file at `/<key>.txt`.
- **OG images** — `GET /og/:key.png` with your own backend (or the optional `ferrum` card renderer), cached,
  with a bounded number of concurrent renders and a fallback image.
- **`rake seo_geo:audit`** — fetches every host's robots.txt, sitemap.xml, llms.txt and listed pages
  in-process and reports title, canonical, noindex, JSON-LD, FAQ, Markdown and shadowing problems. Exits 1 on
  errors; `FORMAT=json` for CI.
- **`rails g seo_geo:install`** — initializer, sample page copy and the engine mount.
- **Test helpers** — `SeoGeo::Testing` Minitest assertions and RSpec matchers (`require "seo_geo/rspec"`)
  built on the audit's checks; `with_seo_geo_environment("production") { ... }` /
  `SeoGeo::Testing.with_environment` to see production robots.txt and sitemaps from a test.
- **`SeoGeo::BotVerifier`** (opt-in) — reverse DNS and published IP ranges tell you whether a request that
  *claims* to be Googlebot or GPTBot really is. The gem itself never uses the User-Agent for access decisions.

<!-- example: install/Gemfile -->
```ruby
# Gemfile
gem "seo_geo"
```

## Status

- Version 0.2.0, released to [RubyGems](https://rubygems.org/gems/seo_geo) on 2026-10-20.
- CI runs Ruby 3.2, 3.3 and 3.4 × Rails 7.2, 8.0 and 8.1 (every cell), each against an ERB app and an
  Inertia-style app.
- Runtime dependencies: `railties`, `actionpack`, `meta-tags ~> 2.24` and `reverse_markdown ~> 3.0`.
  `ferrum` (OG card rendering) and ActiveJob (`SeoGeo::IndexNowJob`) are optional.
- Piloted against a real Rails + Inertia (Svelte) app's codebase (four hostnames folded onto one canonical origin):
  its full request spec suite and `rake seo_geo:audit` pass in a production-like configuration. Not yet deployed
  to production.
- Every code example in this README and in [AGENTS.md](AGENTS.md) lives in [`docs/examples/`](docs/examples)
  and runs in the test suite (`test/docs/`), together with the output it claims.

## Quick start

```sh
bundle add seo_geo
bin/rails g seo_geo:install https://www.example.com
```

The generator writes `config/initializers/seo_geo.rb` and `config/seo_geo/pages/home.yml`. It also mounts the
engine as the last route, so your own routes win where paths overlap. A minimal configuration:

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

<!-- example: quickstart/config/routes.rb -->
```ruby
# config/routes.rb
Rails.application.routes.draw do
  root "pages#home"
  get "/pricing", to: "pages#pricing"
  get "/articles/launch", to: "articles#show"

  mount SeoGeo::Engine, at: "/"  # last, so your own routes win where paths overlap
end
```

One layout line replaces your `<title>`, meta description, canonical link and JSON-LD:

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

Page copy lives in one file per page. `title` and `description` feed the head; `faq` feeds both the visible
FAQ and the FAQPage JSON-LD:

<!-- example: quickstart/config/seo_geo/pages/home.yml -->
```yaml
# config/seo_geo/pages/home.yml — one copy source for the head, the visible FAQ and FAQPage JSON-LD
en:
  title: Plan your week in five minutes
  description: Example turns a messy task list into a weekly plan your whole team can see, in five minutes.
  heading: Plan your week in five minutes
  intro: Example turns a messy task list into a weekly plan your whole team can see.
  faq:
    - question: Is Example free?
      answer: Teams of up to three people use Example for free.
```

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

<!-- example: quickstart/app/views/pages/home.html.erb -->
```erb
<%# app/views/pages/home.html.erb %>
<h1><%= @page.heading %></h1>
<p><%= @page.intro %></p>
<%= seo_geo_faq(@page) %>
```

<!-- example: quickstart/app/views/pages/pricing.html.erb -->
```erb
<%# app/views/pages/pricing.html.erb %>
<h1>Pricing</h1>
<p>Free for up to three people. Paid plans start at $8 per user per month.</p>
```

In production, `GET /pricing` on `example.com` (an alias) renders this head (excerpt):

<!-- output: quickstart GET /pricing Host=example.com -->
```html
<title>Pricing | Example</title>
<meta name="description" content="Free for up to three people; paid plans for larger teams, billed monthly.">
<link rel="canonical" href="https://www.example.com/pricing">
<link rel="alternate" href="https://www.example.com/pricing.md" type="text/markdown">
<meta property="og:locale" content="en_US">
```

`GET /robots.txt` on `www.example.com`: search and user-triggered fetchers share one rule block, and denied
training crawlers get `Disallow: /` plus every host rule:

<!-- output: quickstart GET /robots.txt Host=www.example.com -->
```text
User-agent: *
User-agent: Googlebot
User-agent: OAI-SearchBot
User-agent: ChatGPT-User
Allow: /.well-known/
Disallow: /admin
Content-Signal: search=yes, ai-input=yes, ai-train=no

User-agent: GPTBot
User-agent: ClaudeBot
User-agent: CCBot
Allow: /.well-known/
Disallow: /
Disallow: /admin

Sitemap: https://www.example.com/sitemap.xml
```

A host you did not declare fails closed:

<!-- output: quickstart GET /robots.txt Host=unknown.example.net -->
```text
User-agent: *
Allow: /.well-known/
Disallow: /
```

`GET /llms.txt` links the Markdown form of each listed page:

<!-- output: quickstart GET /llms.txt Host=www.example.com -->
```markdown
# Example

> Example helps small teams plan their week.

## Pages

- [Plan your week in five minutes](https://www.example.com/index.md): Example turns a messy task list into a weekly plan your whole team can see, in five minutes.
```

An agent asking for Markdown gets frontmatter, the main content and `Vary: Accept`:

<!-- curl: quickstart -->
```sh
curl -s -H "Host: www.example.com" -H "Accept: text/markdown" http://localhost:3000/pricing
curl -s -H "Host: www.example.com" http://localhost:3000/pricing.md
```

<!-- output: quickstart GET /pricing Host=www.example.com Accept=text/markdown -->
```text
content-type: text/markdown; charset=utf-8
vary: Accept
content-signal: search=yes, ai-input=yes, ai-train=no
---
title: Pricing | Example
description: Free for up to three people; paid plans for larger teams, billed monthly.
canonical: https://www.example.com/pricing
locale: en
---
# Pricing
Free for up to three people. Paid plans start at $8 per user per month.
```

Then check the whole site. The audit requests every host in-process, as production would serve it, even in
development: it switches seo_geo to the first indexable environment and, outside production, adds the
configured hosts to `config.hosts` for that run only.

```sh
bin/rails seo_geo:audit            # FORMAT=json HOSTS=www.example.com MAX_PAGES=200
```

<!-- output: quickstart audit env=development -->
```text
seo_geo audit: temporarily allowing www.example.com, example.com in config.hosts
seo_geo audit: 0 error(s), 0 warning(s) (1 audited as production, 3 pages, 1 llms_links)
```

On a real app warnings appear in the same line, for example
`seo_geo audit: 0 error(s), 2 warning(s) (1 audited as production, 7 pages, 6 llms_links)`, followed by one
line per finding. Calling `SeoGeo::Audit::Runner` from `bin/rails runner` needs `SEO_GEO_AUDIT=1` set before
boot for the same host allowance.

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

## Inertia (React, Vue, Svelte)

Inertia sends an empty `<div id="app">`, and crawlers that do not run JavaScript (GPTBot, ClaudeBot,
PerplexityBot, Yeti) would see nothing. Pass the page copy as props for people, and render the same copy as a
fallback body for crawlers:

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

<!-- example: inertia/app/frontend/entrypoints/application.js -->
```js
// app/frontend/entrypoints/application.js — after createInertiaApp(...) has mounted:
window.SeoGeo?.mounted() // hides the crawler fallback body for people running JavaScript
```

The server HTML then carries the copy inside `<main data-seo-fallback>`, next to the props:

<!-- output: inertia GET / Host=www.example.com -->
```html
<main data-seo-fallback>
<h1>Plan your week in five minutes</h1>
<p>Example turns a messy task list into a weekly plan your whole team can see.</p>
<h3>Is Example free?</h3>
<p>Teams of up to three people use Example for free.</p>
```

The `seo` prop is `Page#props`: `key`, `locale`, `title`, `description`, `heading`, `intro`, `features`
(`[{title:, description:}]`), `faq` (`[{question:, answer:}]`) and any extra YAML keys. Render the visible
FAQ from `seo.faq`; that keeps it identical to the FAQPage JSON-LD. Extra crawler-only HTML (links to sign-up or legal pages) goes in a block,
`seo_geo_fallback_body(page) { ... }`, or in `content_for(:seo_geo_fallback_extra)`; both land at the end of
`<main>`. The head snippet hides the fallback while
JavaScript runs and shows it again if `mounted()` is not called within five seconds. The tests run this
example with a stand-in for inertia_rails' `render inertia:`; seo_geo does not depend on inertia_rails.

## Configuration reference

Every key, default and validation rule is in [docs/DESIGN.md § Configuration](docs/DESIGN.md#shared-contract).
The ones most apps touch:

| Key | Default | What it does |
|---|---|---|
| `canonical_origin` | nil, **required** | `"https://www.example.com"`; aliases and undeclared hosts fold their canonical URLs onto it, and sitemap `<loc>` and llms.txt links use it |
| `canonical_aliases` | `[]` | hosts folded onto the canonical origin; they inherit its robots rules and serve no sitemap |
| `host(name, indexable:, disallow:, allow:, sitemap:)` | — | per-host robots policy; undeclared hosts get `Disallow: /` |
| `crawlers.training` / `.search` / `.user` | `:allow` | `:allow` or `:deny` per purpose; `crawlers.override "Bytespider", :deny` per token |
| `crawlers.override ua, :full_access` | — | opt-in only: that token gets `Allow: /` and ignores every host `disallow` (e.g. `"Mediapartners-Google"` for AdSense); closed hosts still get `Disallow: /` |
| `site.name` / `.description` / `.default_locale` | nil / nil / `:en` | title suffix, JSON-LD, llms.txt header, `<html lang>`, `og:locale` |
| `title_template` | `"%{title} \| %{site}"` | must contain `%{title}` |
| `indexable_environments` | `["production"]` | everything else is noindex + `Disallow: /` |
| `default_noindex` | false | true: pages opt in with `seo index: true` or `sitemap.add ..., index: true` |
| `noindex_paths` | `[]` | Strings or Regexps; one declaration keeps a path out of sitemap.xml and llms.txt and renders noindex |
| `locales` / `x_default_locale` | `[]` / nil | hreflang alternates; `I18n.locale` is used only when listed |
| `verification.google` / `.bing` / `.naver` / `.daum_pin` | nil | search-console verification |
| `markdown.enabled` / `.selector` | true / `"main, [role=main]"` | Markdown negotiation and the content selector |
| `llms_txt.page` / `.link` / `.details` | — | llms.txt sections; `markdown: true` links the `.md` form |
| `indexnow.enabled` / `.key` | false / nil | IndexNow submission and the `/<key>.txt` key file |
| `og_image.backend` / `.fallback_url` / `.permitted_params` | nil / nil / `[]` | OG images; every permitted param needs a `param_constraints` entry |
| `og_image.fallback_width` / `.fallback_height` | nil / nil | `og:image:width/height` for `fallback_url`, emitted only when both are set |

Sitemap sources: `SeoGeo.sitemap.draw { add "/pricing"; add -> { Post.published }, path: ->(post) { "/posts/#{post.slug}" }, lastmod: :updated_at }`.
Pass collections as a lambda, so boot loads no model and a development reload never keeps a stale class. Records
are read with `find_each` (`select` must include `id`, `order` is ignored); `batch: false` keeps the scope's order.

## What it deliberately does not do

- **No rich-result promises.** It emits FAQPage JSON-LD because AI answers and search engines read it, but
  since 2023 Google shows FAQ rich results only for a few authoritative sites and no longer shows HowTo rich results.
  The gem never adds markup for content that is not on the page.
- **The User-Agent is never identity.** robots.txt is the only place the gem reads crawler names, Markdown is
  chosen by the `Accept` header, and every client gets the same public content. The audit warns when app code
  branches on `request.user_agent`. When a bot must be trusted, use `SeoGeo::BotVerifier` and require
  `verified == true`.
- **llms.txt is generated, not promoted.** Its effect is unproven. Evil Martians measured ~268,000 agent
  requests over two months (2026): `/llms.txt` was fetched ~660 times and `/llms-full.txt` ~110 times, and only
  ~37 of those fetches came from named AI assistants
  ([source](https://evilmartians.com/chronicles/which-ai-actually-reads-your-site-two-months-of-llm-traffic-measured)).
  In the same data, ChatGPT-User made 73% of agent requests and read HTML, while Claude Code asked for
  `Accept: text/markdown` 76% of the time. seo_geo therefore puts server HTML first and Markdown
  negotiation second, and keeps llms.txt cheap.
- **No invented data.** No `Time.now` as `lastmod`, and no prices, ratings or counts it was not given.
- **No geolocation.** GEO here is Generative Engine Optimization.

## Troubleshooting

| Symptom (exact text) | Cause | Fix |
|---|---|---|
| Boot fails: `SeoGeo::ConfigurationError: invalid seo_geo configuration:` / `- canonical_origin is required (e.g. "https://www.example.com")` | Production boot validates the configuration and `canonical_origin` is unset | Set `seo.canonical_origin` or run `bin/rails g seo_geo:install https://www.example.com` |
| Warning: `seo_geo: canonical_origin is not set, so every host is fail-closed (Disallow: /, noindex).` | Same, outside production: boot continues with every host closed | Same fix |
| `canonical_origin must not contain a path, query or fragment (got "https://www.example.com/en")` | The origin has a path | Use the bare origin; localized paths go in `hreflang_url` |
| `title_template must contain %{title}` | A template such as `"%{site}"` | Include `%{title}`, or use `"%{title}"` to drop the suffix |
| `CANONICAL_ORIGIN must look like https://www.example.com (got "example.com")` | Generator argument without a scheme | `bin/rails g seo_geo:install https://www.example.com` |
| `SeoGeo::JsonLd::InvalidNode: Product "Widget" needs offers, review or aggregate_rating` | A typed JSON-LD node lacks a property Google requires | Pass the property, or leave the node out; never invent one |
| `unknown seo option(s): titel (known: title, description, image, noindex, index, canonical, page, type, markdown, json_ld, published_time, modified_time)` | Typo in a controller `seo(...)` call | Use one of the listed keys |
| `KeyError: seo_geo page :pricing is not defined` | No `config/seo_geo/pages/pricing.yml`, I18n scope or `SeoGeo.pages.register` | Add the page copy, or check the key and the YAML locale keys |
| `collections need path: (a callable or a record method name)` | `sitemap.add -> { Post.published }` without `path:` | `add -> { Post.published }, path: ->(post) { "/posts/#{post.slug}" }` |
| `sitemap path "pricing" must start with /` | Relative sitemap path | `add "/pricing"` |
| `.md` URL answers 406 `Not Acceptable: no Markdown version of this page` | The action does not include `SeoGeo::Markdownable` or is outside its `only:`/`except:` | `include SeoGeo::Markdownable` (with `seo_geo_markdown only: ...`), or stop linking the `.md` form (`llms_txt.page ..., markdown: false`) |
| Audit error `host_authorization`: `` Rails HostAuthorization blocked Host: www.example.com; run it through `bin/rails seo_geo:audit` (or set SEO_GEO_AUDIT=1 before boot, e.g. for bin/rails runner) so seo_geo allows its hosts outside production, or add "www.example.com" to config.hosts `` | The audit ran without `SEO_GEO_AUDIT=1` (for example from `bin/rails runner`), or in production, where `config.hosts` is never widened | Use `bin/rails seo_geo:audit`, export `SEO_GEO_AUDIT=1` before booting a runner, or add the host to `config.hosts` |
| Audit error `static.shadowing`: `public/robots.txt is served before the seo_geo route; delete it` | A static file wins over the engine route (the generator warns too) | Delete `public/robots.txt` (or `sitemap.xml`, `llms.txt`, `llms-full.txt`) |
| Audit error `sitemap.noindex`: `listed in sitemap.xml but the page is noindex` | The page sets `seo noindex: true` at request time, which sitemap.xml cannot see | Declare it with `noindex_paths` or `sitemap.add path, noindex: true` |
| Audit warning `code.user_agent_branch`: `branches on the User-Agent header; never use it for access, content or rate-limit decisions (it is spoofable)` | App code branches on `request.user_agent` | Serve everyone the same content; use `SeoGeo::BotVerifier` when a bot must be trusted |
| `og_image.permitted_params "theme" needs an og_image.param_constraints entry` | Every query param that reaches the OG backend must be constrained | `seo.og_image.param_constraints = { "theme" => %w[light dark] }` (or a Regexp) |
| `indexnow.key "robots" collides with another /<name>.txt route` | The key file would shadow `/robots.txt` | Use a random key: `SecureRandom.hex(16)` |
| Warning: `seo_geo: host "127.0.0.1" is not declared (canonical_origin/canonical_aliases/host); serving noindex + Disallow: /. Check proxy Host headers.` | A request reached the app with a host seo_geo does not know: a proxy that drops or rewrites `Host` (here `127.0.0.1`), or an apex/www mismatch. The page is served noindex and robots.txt says `Disallow: /`, which deindexes the site | Forward the original `Host` from the proxy (e.g. nginx `proxy_set_header Host $host;`), or declare the host with `canonical_aliases` / `seo.host` |
| Warning: `seo_geo: invalid configuration ignored while a generator or rake task runs in production (a production server boot raises):` | A production rake task (`assets:precompile`, `db:migrate` in a Docker build) booted without the runtime ENV the configuration reads, e.g. `canonical_origin` | Nothing for the build step; make sure the variable is set where the server boots, which still raises |
| A `GET /<path>.md` route of your own answers 406 `Not Acceptable: no Markdown version of this page` | `SeoGeo::Markdown::PathSuffix` rewrites every `GET *.md` request app-wide | Set `seo.markdown.path_suffix = false` (Markdown stays available with `Accept: text/markdown`) or `seo.markdown.enabled = false`; otherwise keep your `.md` routes out of the app |
| Browsers get Markdown from a CDN, or agents get HTML | Markdownable actions answer `Vary: Accept`; a CDN that ignores `Vary` caches one representation for both | Add `Accept` (or a Markdown/HTML flag derived from it) to the CDN cache key, or bypass the cache for Markdownable paths |
| `GET /og/<key>.png` never reaches the gem's OG renderer | The engine routes `/og/:key.png` only once `og_image.backend` or `.template` is set, and only for known keys (page keys, `og_image.keys`, `key_resolver`); an app route for the same path, drawn above the mount, wins | Set a backend and register the key; remove the overlapping app route, or keep serving those images from your app |

## Development

```sh
bundle exec rake test                                    # unit, docs, and app tests against both dummy apps
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rake test
```

Design and module boundaries: [docs/DESIGN.md](docs/DESIGN.md). Changes: [CHANGELOG.md](CHANGELOG.md).
Guidance for coding agents: [AGENTS.md](AGENTS.md).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
