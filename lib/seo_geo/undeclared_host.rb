# frozen_string_literal: true

require "set"

module SeoGeo
  # Fail-closed hosts are silent by design (noindex + +Disallow: /+), which also hides a misconfiguration: a proxy
  # that drops the Host header (+127.0.0.1+), or an apex/www mismatch, deindexes the whole site. In an indexable
  # environment the robots.txt controller and the head warn once per host per process.
  module UndeclaredHost
    MESSAGE = 'seo_geo: host %<host>s is not declared (canonical_origin/canonical_aliases/host); ' \
              "serving noindex + Disallow: /. Check proxy Host headers."

    @warned = Set.new
    @lock = Mutex.new

    module_function

    # @param host [String, nil] request host
    # @param config [Configuration]
    # @return [Boolean] true when this call logged the warning
    def warn_once(host, config: SeoGeo.config)
      return false unless config.indexable_environment?
      return false if config.host_policy(host.to_s).known

      key = host.to_s.downcase
      return false unless @lock.synchronize { @warned.add?(key) }

      message = format(MESSAGE, host: key.inspect)
      logger = defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
      logger ? logger.warn(message) : Kernel.warn(message)
      true
    end

    # Forgets which hosts were reported (tests).
    # @return [void]
    def reset!
      @lock.synchronize { @warned.clear }
    end
  end
end
