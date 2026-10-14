# frozen_string_literal: true

module SeoGeo
  # Mount at the root so /robots.txt, /sitemap.xml and /llms.txt resolve:
  #   mount SeoGeo::Engine, at: "/"
  class Engine < ::Rails::Engine
    isolate_namespace SeoGeo

    # The same object as SeoGeo.config, so `config.seo_geo.site.name = ...` in
    # config/application.rb and `SeoGeo.configure` in an initializer are interchangeable.
    config.seo_geo = SeoGeo.config

    initializer "seo_geo.pages" do |app|
      default = app.root.join("config/seo_geo/pages").to_s
      SeoGeo.pages.paths |= [default]
    end

    # initializer "seo_geo.helpers" (ActionView/ActionController on_load hooks).
    initializer "seo_geo.helpers" do
      ActiveSupport.on_load(:action_view) do
        include SeoGeo::Meta::Helper
        include SeoGeo::CrawlerFallback::Helper
      end
      ActiveSupport.on_load(:action_controller_base) { include SeoGeo::Controller }
    end

    # initializer "seo_geo.mime" (Mime::Type.register "text/markdown", :md).
    initializer "seo_geo.mime" do |app|
      Mime::Type.register "text/markdown", :md unless Mime::Type.lookup_by_extension(:md)
      # /<path>.md and /index.md for every route; appended, so ActionDispatch::Static (public/*.md) wins.
      app.middleware.use SeoGeo::Markdown::PathSuffix
    end

    # IndexNow job (only when ActiveJob is loaded) and the seo_geo_indexnow model macro.
    initializer "seo_geo.index_now" do
      Rails.autoloaders.main.ignore(root.join("app/jobs")) unless defined?(ActiveJob::Base)
      ActiveSupport.on_load(:active_record) { extend SeoGeo::Model }
    end

    config.after_initialize do
      SeoGeo::Engine.check_configuration!
    end

    # +rake seo_geo:audit+ requests the production host names in-process. Outside production Rails
    # HostAuthorization (config.hosts, e.g. [".localhost"]) would answer 403 for them, and config.hosts is copied
    # when the middleware stack is built — so with SEO_GEO_AUDIT=1 (set by the rake task; set it yourself for
    # +bin/rails runner+) the configured hosts are appended here, after the app's initializers and before the stack
    # is built. Never in production, never without the flag, never when config.hosts is empty (allows all).
    AUDIT_FLAG = "SEO_GEO_AUDIT"

    initializer "seo_geo.audit_hosts", after: :load_config_initializers, before: :build_middleware_stack do |app|
      SeoGeo::Engine.allow_audit_hosts!(app.config)
    end

    # @param app_config [Rails::Application::Configuration]
    # @param env [Hash] process environment (the flag)
    # @param production [Boolean]
    # @return [Array<String>] hosts appended to +config.hosts+ (empty when nothing was changed)
    def self.allow_audit_hosts!(app_config, env: ENV, production: Rails.env.production?, logger: Rails.logger)
      return [] if production || env[AUDIT_FLAG] != "1"
      return [] unless app_config.respond_to?(:hosts) && !app_config.hosts.empty?

      added = SeoGeo.config.known_hosts - app_config.hosts.map(&:to_s)
      return [] if added.empty?

      app_config.hosts.concat(added)
      message = "seo_geo audit: temporarily allowing #{added.join(", ")} in config.hosts"
      logger&.info(message)
      Kernel.warn(message)
      added
    end

    MISSING_ORIGIN = "seo_geo: canonical_origin is not set, so every host is fail-closed (Disallow: /, noindex). " \
                     "Run bin/rails g seo_geo:install https://www.example.com or set it in config/initializers/seo_geo.rb."

    PRODUCTION_TOOLING = "seo_geo: invalid configuration ignored while a generator or rake task runs in production " \
                         "(a production server boot raises):"

    # Boot-time validation that cannot lock a fresh app out of its own installer or build:
    # - production server boot: {Configuration#validate!} raises on any problem;
    # - production generator/rake task (+assets:precompile+, +db:migrate+ in a Docker build where the origin comes
    #   from runtime ENV): warns and continues;
    # - generators and rake tasks elsewhere: skipped (+rails g seo_geo:install+ must boot before the initializer exists);
    # - otherwise a missing +canonical_origin+ only logs a warning; other problems still raise.
    # @return [void]
    def self.check_configuration!(config: SeoGeo.config, production: Rails.env.production?, tooling: tooling?,
                                  logger: Rails.logger)
      if production
        return config.validate! unless tooling

        problems = config.errors
        unless problems.empty?
          message = "#{PRODUCTION_TOOLING}\n- #{problems.join("\n- ")}"
          logger&.warn(message)
          Kernel.warn(message)
        end
        return
      end
      return if tooling

      if config.canonical_origin.nil?
        logger&.warn(MISSING_ORIGIN)
        Kernel.warn(MISSING_ORIGIN)
        problems = config.errors.reject { |message| message.start_with?("canonical_origin is required") }
        raise ConfigurationError, "invalid seo_geo configuration:\n- #{problems.join("\n- ")}" unless problems.empty?
        return
      end
      config.validate!
    end

    # @return [Boolean] true while +rails generate/destroy+ boots the app (their command classes are loaded only
    # for those commands, before boot) or a rake task runs (+rails db:migrate+, +rake ...+). Merely having
    # +rails/generators+ loaded does not count.
    def self.tooling?
      return true if defined?(::Rails::Command::GenerateCommand) || defined?(::Rails::Command::DestroyCommand)
      return false unless defined?(::Rake) && ::Rake.respond_to?(:application)

      !::Rake.application.top_level_tasks.empty?
    end

    # lib/tasks/*.rake is loaded by Rails::Engine itself; loading it again here ran every task twice.
  end
end
