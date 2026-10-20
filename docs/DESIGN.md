# seo_geo — design

This file is the design contract for the gem. Names and signatures in § Public API and § Shared contract are
fixed; changing one requires updating this file in the same change.

## Principles

1. Server HTML + meta first (ChatGPT-User, ~73% of agent traffic, reads HTML). Markdown negotiation
   second (Claude Code requests `Accept: text/markdown` ~76% of the time). llms.txt is generated, not invested in.
2. One crawler policy object (`config.crawlers`) drives robots.txt groups, the `Content-Signal` header/line
   and AIPREF `Content-Usage` (experimental, off by default).
3. One copy source per page (`SeoGeo.page(:key)`) feeds crawler HTML, JSON-LD and Inertia props, so
   FAQPage JSON-LD always matches the visible text.
4. Fail closed: an undeclared host gets `Disallow: /` (except `allow_exceptions`, default `/.well-known/`)
   and a 404 sitemap. In an indexable environment the robots.txt controller and the head log one warning per
   undeclared host per process (`SeoGeo::UndeclaredHost`) — a proxy that drops Host would otherwise deindex silently. Non-production environments are noindex + `Disallow: /` everywhere.
5. Never invent data: no `Time.now` lastmod, no rich-result promises for FAQ/HowTo.

## Module boundaries

| Area | Files | Public API |
|---|---|---|
| Core | `lib/seo_geo.rb`, `lib/seo_geo/{configuration,crawlers,page,version,engine}.rb`, `lib/seo_geo/sitemap/registry.rb`, `lib/seo_geo/{robots_path,robots_directives,safe_regexp,undeclared_host}.rb` | `SeoGeo.configure`, `SeoGeo.config`, `SeoGeo.sitemap`, `SeoGeo.pages`, `SeoGeo.page` |
| Head | `lib/seo_geo/meta.rb`, `lib/seo_geo/json_ld.rb`, `lib/seo_geo/json_ld/**`, `lib/seo_geo/crawler_fallback.rb`, `app/helpers/seo_geo/**`, `app/views/seo_geo/head/**`, `app/views/seo_geo/fallback/**`, `lib/seo_geo/controller.rb` | `seo_geo_head`, `seo_geo_fallback_body(key)`, `seo_geo_html_lang`, controller `seo(title:, description:, image:, noindex:, index:, canonical:, type:, published_time:, modified_time:)`, `SeoGeo::Page#json_ld`, `SeoGeo::JsonLd` builder, JS `window.SeoGeo.mounted()` |
| Crawler files | `app/controllers/seo_geo/{robots,sitemaps,llms}_controller.rb`, `lib/seo_geo/robots.rb`, `lib/seo_geo/sitemap/xml.rb`, `lib/seo_geo/llms_txt.rb`, `app/views/seo_geo/{robots,sitemaps,llms}/**` | `GET /robots.txt`, `GET /sitemap.xml`, `GET /llms.txt`, `GET /llms-full.txt` |
| Markdown, IndexNow, OG | `lib/seo_geo/markdownable.rb`, `lib/seo_geo/markdown/**`, `lib/seo_geo/index_now.rb`, `app/jobs/seo_geo/**`, `app/controllers/seo_geo/{index_now,og_images}_controller.rb`, `lib/seo_geo/og_image/**`, `lib/seo_geo/model.rb` | `SeoGeo::Markdownable`, `SeoGeo::IndexNow.submit(urls)`, model macro `seo_geo_indexnow on: :publish`, `GET /<key>.txt`, `GET /og/:key.png` |
| Audit and testing | `lib/tasks/seo_geo.rake`, `lib/seo_geo/publication.rb`, `lib/seo_geo/audit.rb`, `lib/seo_geo/audit/**`, `lib/generators/seo_geo/**`, `lib/seo_geo/testing.rb`, `lib/seo_geo/testing/**`, `lib/seo_geo/rspec.rb`, `lib/seo_geo/robots/evaluator.rb`, `lib/seo_geo/bot_verifier.rb`, `lib/seo_geo/path_match.rb` | `rake seo_geo:audit`, `rails g seo_geo:install`, Minitest assertions + RSpec matchers, `SeoGeo::Robots::Evaluator`, `SeoGeo::BotVerifier` (+ `::Middleware`) |

Engine initializers are named `"seo_geo.<topic>"` (helpers, mime, index_now, audit_hosts). `test/dummy*/` share
`test/support/dummy_base.rb`; controllers there are fixtures named after the feature they exercise.

New configuration keys: add to `lib/seo_geo/configuration.rb` with a default, a YARD comment, an
`errors` entry when it can be invalid, and a test in `test/unit/configuration_test.rb`. Do not rename keys.

## Mounting

Apps mount at the root so the well-known paths resolve: `mount SeoGeo::Engine, at: "/"`. The generator inserts
the mount **last** in `config/routes.rb` — once, directly inside `routes.draw` (never in a scope/namespace), before
the first top-level catch-all `get "*path"`, else before the closing `end`; an existing mount is left alone — so app
routes win where paths overlap.
Engine routes must never claim a path they then 404 (a controller 404 does not cascade): `/og/:key.png` matches only
through `SeoGeo::OgImage::RouteConstraint` — `og_image.enabled?` (backend or template set, or `enabled = true`) and a
known key (page key, `og_image.keys`, `key_resolver`); anything else falls through to the app (e.g. `/og/:username.png`).
A `key_resolver` that raises claims the request so the controller answers with the `fallback_url` redirect (else 404)
— falling through would hand a resolver outage to an unrelated app route.

Boot validation (`SeoGeo::Engine.check_configuration!`, after_initialize): production raises on any configuration
error on a server boot and only warns while a generator or rake task runs (`assets:precompile`/`db:migrate` in a
Docker build without runtime ENV); while `rails generate`/`destroy` (their command classes, loaded before boot — merely requiring
`rails/generators` does not count) or a rake task runs outside production it is skipped (the installer must boot before the
initializer exists); otherwise a missing `canonical_origin` logs a warning (every host stays fail-closed) and other
errors raise.
Robots/sitemap/llms controllers inherit `ActionController::API` (avoids `allow_browser` 406 for bots).
A static `public/robots.txt`, `public/sitemap.xml` or `public/llms.txt` wins over routes — the generator
and the audit warn about it.

## Shared contract

### Configuration (`SeoGeo.config`, also `Rails.application.config.seo_geo` — the same object)

Validated by `SeoGeo.config.validate!` in `after_initialize`; `errors` returns every problem at once.

| Key | Default | Notes |
|---|---|---|
| `site.name` / `site.description` / `site.logo_url` | nil | WebSite/Organization JSON-LD, title `%{site}`, llms.txt H1/blockquote |
| `site.default_locale` | `:en` | `<html lang>`, `WebSite.inLanguage`, `og:locale`, page-copy fallback. `config.request_locale(I18n.locale)` uses `I18n.locale` only when `locales` lists it (also the default for `SeoGeo.page`, `seo_geo_page` and the crawler fallback); `config.og_locale` maps `ko` => `ko_KR`, `en-GB` => `en_GB` |
| `site.same_as` | `[]` | Organization.sameAs |
| `canonical_origin` | nil (**required**) | `"https://www.example.com"`, no path; trailing slash stripped |
| `canonical_aliases` | `[]` | hosts folded onto the canonical origin; without their own `host(...)` they inherit the canonical host's `indexable`/`disallow`/`allow` (share prefixes and allow exceptions apply everywhere) and serve no sitemap |
| `canonical_exclude_hosts` | `[]` | hosts that keep their own canonical (e.g. store) |
| `canonical_keep_params` | `[]` | query params kept in canonical URLs |
| `host(name, indexable: true, disallow: [], allow: [], sitemap: nil)` | — | per-host policy; `sitemap: nil` = `indexable` |
| `unknown_host` | `:fail_closed` | only supported mode |
| `allow_exceptions` | `["/.well-known/"]` | allowed even on fail-closed / disallowed hosts |
| `share_prefixes` | `[]` | e.g. `"/s/"`, `"/go/"` — open for link-preview bots |
| `locales` / `x_default_locale` / `hreflang_url` | `[]` / nil / nil | hreflang; nil url proc => `?locale=` |
| `verification.google/bing/naver/daum_pin` | nil | meta tags; Daum PIN goes into robots.txt |
| `crawlers.training/search/user` | `:allow` | `:allow` or `:deny` per purpose |
| `crawlers.add(purpose, *uas)` / `crawlers.override(ua, policy)` | — | extend groups / per-token policy `:allow`, `:deny` or `:full_access`. `:full_access` is opt-in only (never a default): its own group with `Allow: /` plus `allow_exceptions` — **it ignores every host `disallow`** (e.g. `Mediapartners-Google`); a closed host (non-indexable host/environment, undeclared host) still gets `Disallow: /` from `*` |
| `content_signal` | nil | nil derives `{search:, ai_input:, ai_train:}` from `crawlers` |
| `aipref.enabled` | false | experimental `Content-Usage` |
| `environment` / `indexable_environments` | Rails.env / `["production"]` | others => noindex + `Disallow: /` |
| `title_template` | `"%{title} \| %{site}"` | must contain `%{title}` |
| `description_max_length` | 160 | truncated on a word boundary with `…` |
| `default_noindex` | false | true => opt-in indexing per controller |
| `markdown.enabled` / `.content_signal_header` / `.converter` / `.selector` / `.path_suffix` | true / true / `:reverse_markdown` / `"main, [role=main]"` / true | converter may be a callable; no selector match => `<body>` minus header/footer/aside; `path_suffix: false` turns off the `/<path>.md` middleware (apps with their own `.md` routes) — Markdown stays available through `Accept: text/markdown`, and the head, llms.txt and the audit stop using `.md` URLs |
| `indexnow.key` / `.endpoint` / `.enabled` / `.dry_run` / `.batch_size` | nil / api.indexnow.org / false / nil / 10000 | `dry_run: nil` = dry-run outside indexable environments |
| `og_image.backend` / `.template_version` / `.width` / `.height` / `.fallback_url` / `.permitted_params` / `.template` | nil / "1" / 1200 / 630 / nil / `[]` / nil | backend `(key, page, params) -> PNG bytes`; only permitted query params reach the backend and the cache key; `template` = ERB for the ferrum backend. `og:image:width/height` only when the size is known: explicit `seo image: {url:, width:, height:}`, a gem-rendered `/og/<key>.png` (og_image enabled => `width`x`height`), or `fallback_url` with `og_image.fallback_width`/`.fallback_height` (both nil by default) |
| `og_image.enabled` | nil | nil => route `/og/:key.png` only when `backend` or `template` is set; true also serves the bundled ferrum card |
| `og_image.keys` / `.key_resolver` / `.param_constraints` / `.max_param_length` / `.cache_ttl` / `.max_concurrent` | `[]` / nil / `{}` / 100 / 604800 (7 days) / 2 | only `SeoGeo.pages` keys, `keys` or a truthy `key_resolver.(key)` (a returned `Page` is used) render, else 404; every permitted param needs a constraint (Regexp whole-match or allowed values), violations => 400; cache `expires_in: cache_ttl`; at most `max_concurrent` renders per process, beyond that fallback redirect or 503 `Retry-After` (never queued) |
| `cache_control_seconds` | 3600 | robots, sitemap, llms responses |
| `noindex_paths` | `[]` | Exact path Strings or Regexps (percent-decoded path, query ignored); `config.noindex_path?(path)`. Drives robots meta noindex (wins over `seo index: true`), sitemap.xml and llms.txt |
| `llms_txt.enabled` / `.full` / `.details` / `.default_section` | true / true / nil / "Pages" | `details` = free Markdown after the blockquote (H1/H2 demoted to H3, H3+ kept, fenced code untouched); `llms_txt.page(key, path:, section:, optional:, hosts:, markdown: nil)`, `llms_txt.link(title, path, description:, section:, optional:, hosts:, markdown: nil)`; `markdown:` = link the `.md` form: `page` nil => `markdown.enabled` (registered copy; audit flags non-Markdownable actions), `link` only when true; other origins never rewritten; no links => static sitemap paths, `.md` only for `sitemap.add ..., markdown: true` |

Derived helpers to use instead of re-implementing:

- `config.canonical_url(url_or_path)` — folding (aliases/unknown -> canonical; excluded/declared hosts keep their own; query dropped except kept params; non-ASCII percent-encoded once).
- `config.host_policy(host)` -> `SeoGeo::HostPolicy(host, indexable, disallow, allow, sitemap, known)`; `#disallow_all?`.
- `config.known_hosts`, `config.origin_for(host)`, `config.indexable_environment?`, `config.environment_name`.
- `config.format_title(title)`, `config.truncate_description(text)`.
- `config.content_signals`, `config.content_signal_value` (`"search=yes, ai-input=yes, ai-train=no"`), `config.content_usage_value` (`"train-ai=n, search=y"` or nil).
- `config.verification.meta_tags` -> `{ "google-site-verification" => ... }`.
- `config.crawlers.user_agents(purpose)`, `config.crawlers.policy_for(ua)`, `config.effective_x_default_locale`.

### Crawler table (`SeoGeo::Crawlers`)

`PURPOSES = %i[training search user]`; `ALL` — frozen `Crawler(user_agent, owner, purpose, honors_robots, token_only)`;
`DEFAULT_USER_AGENTS[purpose]`; `Crawlers.find(token_or_header)`.

robots.txt rule (RFC 9309: a bot obeys only the most specific group naming it): every group that
seo_geo emits must carry the full host `Disallow` list and `allow` list. The robots builder either repeats the
rules per group or emits several `User-agent:` lines sharing one rule block. An `Allow: /`-only AI
group is a bug (it re-opens `/admin`-style paths to that bot).

### Sitemap registry (`SeoGeo.sitemap` -> `SeoGeo::Sitemap::Registry`)

```ruby
SeoGeo.sitemap.draw { ... }                       # instance_eval DSL
SeoGeo.sitemap.add(path_or_scope, path: nil, lastmod: nil, priority: nil, changefreq: nil, hosts: nil,
                   noindex: false, index: false, markdown: nil, match: nil, batch: nil) # => Entry  (markdown: true => llms fallback links .md; false => audit skips Markdown)
                                                  # match: (collections) Regexp or ->(path) { bool }: which request paths are its records
SeoGeo.sitemap.noindex?(path)                     # static entries added with noindex: true (every host)
SeoGeo.sitemap.index?(path, host: nil, config:)   # index: true entries for host covering path: static path or collection match:
SeoGeo.sitemap.markdown_disabled?(path)           # static entries added with markdown: false (audit skips Markdown checks)
SeoGeo.sitemap.exclude(*patterns)                 # String (exact path) or Regexp
SeoGeo.sitemap.excluded?(path)
SeoGeo.sitemap.each_url(host, config: SeoGeo.config) { |url| }   # Sitemap::Url(loc, lastmod, priority, changefreq)
SeoGeo.sitemap.entries / .exclusions / .clear
```

- Collections are stored unevaluated and enumerated per request; they need `path:` (callable or record method
  name). Prefer a lambda source, `add -> { Post.published }, path: ...`: it is called per sitemap request, so boot
  loads no model and dev reloads never keep a stale class (a scope passed directly is captured at boot).
  Records are read with `find_each` when the scope has it — batches by primary key, so `select` must include `id`
  and `order` is ignored; `batch: false` uses `each` and keeps the scope's order (loads all records at once). `lastmod:` is a date, a record method name or a callable.
- `hosts: nil` lists the entry on the canonical host only.
- sitemaps controller: 404 when `host_policy(host).sitemap` is false; split into a sitemap index above 50,000 URLs;
  add `Cache-Control: public, max-age=<cache_control_seconds>`; also drop pages rendered noindex.
- Publication contract: `SeoGeo::Publication.publishable?(host, path, config:, sitemap:)` is the one
  predicate behind sitemap.xml (`Sitemap::Xml#listable?`), llms.txt link selection and llms-full.txt. A path is
  publishable when the host serves a sitemap, robots does not disallow it (host allow/disallow, longest match),
  it is not `sitemap.exclude`d, not declared noindex (`config.noindex_paths`, `add path, noindex: true`) and — under
  `default_noindex` — declared indexable (`add path_or_scope, index: true`, the registry twin of `seo index: true`).
  Head: `Publication.declared_noindex?(path)` => robots noindex even with `seo index: true` (every host);
  `Publication.declared_index?(host, path)` => indexable under `default_noindex` when an `index: true` entry for that
  host covers the path — a static path (honoring `hosts:`) or a collection record matched by its `match:`.
  A collection added `index: true` without `match:` is listed in sitemap.xml but its head needs `seo index: true`;
  the audit warns (`sitemap.collection_index`) and reports each listed noindex record (`sitemap.noindex`).
  `noindex:` is static-only and exclusive with `index:`.
  **By design**, request-time `seo noindex: true` (controller only) stays invisible to sitemap.xml/llms.txt: they are
  built without running controllers. `rake seo_geo:audit` fetches every listed page and reports it
  (`sitemap.noindex`), reading every robots meta, crawler-specific metas (`googlebot`), `none` and `X-Robots-Tag`
  through `SeoGeo::RobotsDirectives`. Declare such paths with `noindex_paths` or `add path, noindex: true` instead.
  llms.txt links to other origins pass through.
- Shared primitives. Never re-implement these:
  - `SeoGeo::RobotsPath` — RFC 9309 §2.2.2 normalization for rules **and** candidates (unreserved escapes and
    `%24`/`%2A` decoded, other escapes upper-cased and kept: `%2F`/`%3F`/`%23` are not delimiters; non-ASCII encoded).
    `target` (query kept, robots matching), `path` (query dropped, declarations), `html_path` (query dropped, then
    `.md` mapped to its HTML page: `/secret.md?x=1` => `/secret`), `html_target` (the same with the query kept, for
    robots rules such as `Disallow: /secret?preview=1`), `compile`/`decide`/`blocked?` (longest match).
    Used by `Robots::Evaluator`, `Publication`, `PathMatch` (noindex_paths, registry), llms.txt, sitemap.xml, Meta.
  - `SeoGeo::RobotsDirectives` — `{global: Set, scoped: {bot => Set}}` from all robots metas, crawler metas and
    `X-Robots-Tag` (`bot:` scoping; `unavailable_after` dates keep their comma); `none` => noindex, nofollow; `merge` never lets a scoped directive stand in for
    a global one. Used by the Markdown response header and the audit.
  - `SeoGeo::SafeRegexp` — every configuration Regexp matched against request input (og_image constraints,
    noindex_paths, sitemap.exclude, collection `match:`) runs with a 50 ms timeout and a 4096-char cap; a timeout
    resolves restrictively (OG => 400, noindex => noindex, exclude => excluded, `match:` => not indexable).
  - robots.txt denied groups repeat **every** host disallow verbatim (no prefix selection that encodings could defeat).

### Page content (`SeoGeo.pages` -> `SeoGeo::PageRegistry`, `SeoGeo.page(key, locale: nil)` -> `SeoGeo::Page`)

```ruby
SeoGeo.pages.register(:key, hash_or_locale_hash)            # Ruby source (highest precedence)
SeoGeo.pages.register_i18n(:key, scope: "views.x.seo", faq: :list | :numbered)  # q1_q / q1_a ...
SeoGeo.pages.paths                                          # YAML dirs; engine adds <app>/config/seo_geo/pages
SeoGeo.pages.fetch(key, locale:) / .keys / .clear
```

`Page` (frozen Data): `key locale title description heading intro features faq extra`, `#props`, `#to_markdown`,
`#intro_paragraphs`. `intro` is a String or an Array of Strings (paragraphs). `features` items are
`{title:, description:}` (`name`/`body` accepted in sources); `faq` items are `{question:, answer:}` (`q`/`a` accepted
in sources, never in output). `#props` (Symbol keys, all always present, detached mutable copy):
`{ key:, locale:, title:, description:, heading:, intro: (as written: String | Array | nil),
features: [{ title:, description: }], faq: [{ question:, answer: }], **extra }`; extra source keys (e.g. `cta`,
`features_heading`, `faq_heading`) are merged at the top level.
Fallback body (`seo_geo_fallback_body(key, locale: nil) { extra HTML }`): H1 = `heading || title`, one `<p>` per intro
paragraph, features under `extra[:features_heading]` (else `t("seo_geo.fallback.features", default: "Features")`),
FAQ under `extra[:faq_heading]` (else `t("seo_geo.fallback.faq", default: "FAQ")`), then the block's HTML and
`content_for(:seo_geo_fallback_extra)` at the end of `<main>`.
YAML is flat or keyed by locale; missing locale falls back to `site.default_locale`.
`Page#json_ld` (FAQPage built from `faq`, so it matches the fallback body).

### Markdown URL (the head advertises, `Markdownable` serves)

`SeoGeo::Meta.markdown_url_for(canonical_url)`: `/` -> `/index.md`, `/a/` -> `/a/index.md`, `/a` -> `/a.md`,
query kept. `seo_geo_head` emits `<link rel="alternate" type="text/markdown" href=...>` with it when
`markdown.enabled`, the page is indexable, the controller did not pass `seo markdown: false` and the action
serves Markdown (`seo_geo_markdown_available?`: includes `SeoGeo::Markdownable` and is covered by its
`only:`/`except:`; `seo markdown: true` forces the link). A `.md` URL for any other action is a plain 406.

## Public API (target, all phases)

- Layout: `<%= seo_geo_head %>` (meta-tags + canonical + hreflang + verification + `<link rel="alternate" type="text/markdown">` + JSON-LD), `<%= seo_geo_fallback_body(:home) %>`, `seo_geo_html_lang`.
- Controller: `seo title:, description:, image:, noindex:, index:, canonical:, type:, published_time:, modified_time:`; `include SeoGeo::Markdownable`.
  `published_time` and `modified_time` accept Time, Date (including DateTime), or ISO 8601 strings; they emit
  `article:published_time` / `article:modified_time` only for `type: "article"`. Values serialize as ISO 8601,
  preserving offsets and date-only precision. Missing values are omitted; invalid article values raise ArgumentError.
  Never substitute the current time for an unknown publication or modification date.
- JSON-LD extension point: `content_for(:seo_geo_json_ld)`; escaping via `ERB::Util.json_escape` only; CSP nonce honored.
- `SeoGeo::IndexNow.submit(urls)`; model `seo_geo_indexnow on: :publish`.
- `rake seo_geo:audit` (`FORMAT=json`, `HOSTS=a,b`, `MAX_PAGES=200`; exit 1 on errors) = `SeoGeo::Audit::Runner.new(app:, root:).run` -> `Audit::Report`.
  Requests carry `Host` (`HTTP_HOST`, port only when non-default) and `SERVER_NAME`, so Rails `config.hosts` applies;
  a HostAuthorization 403 is reported as `host_authorization` (detected from the app's `config.hosts`, since Rails
  sends an empty body without detailed exceptions). Outside production the task sets `SEO_GEO_AUDIT=1` before
  `:environment`; with that flag the engine initializer `seo_geo.audit_hosts` (after the app's initializers, before
  `build_middleware_stack`, which copies `config.hosts`) appends every configured host to a non-empty `config.hosts`
  and logs `seo_geo audit: temporarily allowing <hosts> in config.hosts`. Never in production, never without the
  flag. For `bin/rails runner` audits, run `SEO_GEO_AUDIT=1 bin/rails runner ...`.
- `SeoGeo::Audit::RackFetcher.new(app:, config:).fetch(host, path, headers = {})` preserves the Rack transport;
  `Runner.new(app:, fetcher: nil, ...)` accepts a replacement transport without changing its checks.
- `SeoGeo::Audit::HttpFetcher.new(origin:, delay: 0.5, timeout: 10).fetch(host, path, headers = {})` uses Net::HTTP,
  one request at a time, 0.5 seconds between requests (including origins and redirect probes), no automatic retries,
  10-second connect/read/write timeouts and `seo_geo-audit/<VERSION>` as User-Agent. HTTP(S) URLs only, no credentials.
  It returns the original response without replacing a redirect with its destination; `chain` records the initial
  response and up to five explicit redirect probes (`url`, `status`, `headers`). Loops/invalid targets/limit failures
  populate `redirect_error`. A trace longer than one hop warns; unfinished traces error.
- `SeoGeo::Audit::Remote.run(urls, io: $stdout, config: SeoGeo.config, max_pages: 200, delay: 0.5, timeout: 10, format: :text)`
  returns `Audit::Report` and prints to `io` (nil suppresses output). Rake `URL=...` / `URLS=a,b` selects it before
  invoking any Rails environment task; it never changes configuration/environment/host authorization or scans source.
  Explicit targets plus each origin's robots/sitemap/home/llms responses use the same Runner/Checks. Without a
  matching host configuration it uses an isolated observation configuration (no change to the app's fail-closed
  policy), checks canonical against that origin and robots blocking against `*`. Matching config enables canonical
  folding, intentional crawler denials and robots comparison. External sitemap pages are reported but not crawled.
  Remote errors: `page.x_robots_noindex` for X-Robots-Tag noindex/none (global or scoped, including redirect probes),
  `page.redirect` for incomplete chains. Warnings: `page.redirect_chain` (>1 hop), `robots.mismatch` (body differs
  from `Robots.new(config, host).to_s`, only for a known host). Existing Markdown checks also verify Vary: Accept.
- Both modes request `/seo-geo-audit-<16hex>` once per host (`page.soft_404` error on any 2xx) and collect
  `description.duplicate` warnings like `title.duplicate`, excluding empty descriptions and noindex pages.
- `rails g seo_geo:install [CANONICAL_ORIGIN] [--site-name=NAME]`.
- Test helpers: `require "seo_geo/testing"` + `include SeoGeo::Testing::Assertions` (`assert_seo_geo_canonical`,
  `assert_seo_geo_single_title`, `assert_seo_geo_faq_matches_visible`, `assert_seo_geo_sitemap`, `assert_seo_geo_no_sitemap`,
  `assert_/refute_seo_geo_robots_allows`); `require "seo_geo/rspec"` (`have_seo_geo_canonical`, `have_seo_geo_single_title`,
  `have_seo_geo_faq_matching_visible_text`, `be_seo_geo_valid_sitemap(origin:)`, `seo_geo_robots_allow(ua, path)`).
  Both use `SeoGeo::Audit::Checks`, the same checks as the audit. Environment switch:
  `SeoGeo::Testing.with_environment("production") { ... }` (module function) and `with_seo_geo_environment(name) { }`
  in both the Minitest assertions and the RSpec helpers; the previous `config.environment` is restored.
- `SeoGeo::Robots::Evaluator.new(body).allowed?(ua_or_header, path)` (RFC 9309 groups, longest match, `*`/`$`).
- `SeoGeo::BotVerifier` (opt-in, `config.middleware.use SeoGeo::BotVerifier::Middleware`): `env["seo_geo.bot"] =
  {name:, purpose:, claimed:, verified: true|false|nil, signed:}`. Never used by the gem for access decisions;
  the User-Agent is only read to choose robots.txt wording.

## Tests

- `test/unit/**` — no Rails app booted.
- `test/app/**` — run twice by `rake test`: against `test/dummy` (ERB layout) and `test/dummy_inertia`
  (empty `<div id="app" data-page=...>`), one process each (`SEO_GEO_DUMMY`). Use `inertia_dummy?` to branch.
- CI: Ruby 3.2/3.3/3.4 × `gemfiles/rails_7_2|8_0|8_1.gemfile` (every cell supported).
