# Changelog

## 0.2.0 - 2026-10-20

- Add standalone remote audits (`URL` / `URLS`, `Audit::Remote.run`) with shared checks, Rack/HTTP fetchers,
  serial paced requests, bounded redirect tracing, X-Robots-Tag errors and configured robots comparison.
- Detect soft-404 responses with a random missing path on each audited host, in-process and remotely.
- Warn when indexable pages on the same host share a meta description.
- Support `seo published_time:` / `modified_time:` as ISO 8601 article Open Graph tags, with executable examples.

## 0.1.0 - 2026-10-14

First release.

- Configuration: one `SeoGeo.configure` (also `config.seo_geo`) validated at boot — production server boots raise,
  production generator/rake tasks and non-production boots warn; purpose-based crawler table
  (`crawlers.training/search/user`, per-token `override` including opt-in `:full_access`); per-host policies with
  fail-closed unknown hosts (logged once per host in indexable environments); alias hosts inherit the canonical
  host's policy; canonical URL folding (`canonical_aliases`, `canonical_exclude_hosts`, `canonical_keep_params`).
- Head: `seo_geo_head` (single `<title>` via `title_template`, description truncation, folded canonical, hreflang +
  x-default, robots noindex for non-indexable hosts/environments, `default_noindex` and declared noindex paths,
  verification metas, Open Graph/Twitter with `og:image` size only when known, `og:locale` from one locale rule,
  Markdown alternate link, JSON-LD `@graph` with CSP nonce and `json_escape`); controller `seo(...)` and
  `seo_geo_page`; `SeoGeo::JsonLd` builder with required-field checks; crawler fallback body (`seo_geo_fallback_body`
  with an extra slot, `seo_geo_faq`) and `window.SeoGeo.mounted()`.
- Page copy: `SeoGeo.page(key)` from Ruby, I18n or YAML — one source for crawler HTML, FAQPage JSON-LD and
  Inertia props (`Page#props`, `intro` as String or Array).
- Crawler files: per-host `GET /robots.txt` (RFC 9309; every named group carries the host rules; Content-Signal,
  optional AIPREF Content-Usage, Daum PIN), `GET /sitemap.xml` with a sitemap index above 50,000 URLs and lazy
  collection sources (`add -> { scope }`, `batch: false`), `GET /llms.txt` and `/llms-full.txt`.
- One publication rule (`SeoGeo::Publication`) behind sitemap.xml, llms.txt and the head: robots disallow,
  exclusions, `noindex_paths` / `sitemap.add ..., noindex: true`, `default_noindex` + `index: true` (with `match:`
  for collections). Paths compare in RFC 9309 form (`SeoGeo::RobotsPath`); configuration Regexps run with a timeout
  (`SeoGeo::SafeRegexp`).
- Markdown for agents: `SeoGeo::Markdownable` (Accept negotiation and `.md` URLs — `markdown.path_suffix` turns the
  URL form off — YAML frontmatter, JSON-LD fences, `Vary: Accept`, `Content-Signal`, robots directives carried into
  `X-Robots-Tag`), page-copy Markdown for Inertia mount points.
- IndexNow: `SeoGeo::IndexNow.submit`, `SeoGeo::IndexNowJob`, dry run outside indexable environments,
  `/<key>.txt`, model macro `seo_geo_indexnow`.
- OG images: `GET /og/:key.png` with a pluggable backend or the optional ferrum renderer, routed only when
  configured and only for known keys, constrained params, cache TTL, concurrency cap and fallback redirect.
- Audit and testing: `rake seo_geo:audit` (in-process, works with a development `config.hosts`), `rails g
  seo_geo:install` (mounts the engine after the app's routes), Minitest assertions and RSpec matchers
  (`with_seo_geo_environment`), `SeoGeo::Robots::Evaluator`, opt-in `SeoGeo::BotVerifier`.
- CI: Ruby 3.2–3.4 × Rails 7.2/8.0/8.1, each against an ERB app and an Inertia-style app; README and AGENTS.md
  examples run in the test suite.
