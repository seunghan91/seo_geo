# frozen_string_literal: true

module SeoGeo
  # Declaration matching shared by {Configuration#noindex_path?} and {Sitemap::Registry} (+noindex?+,
  # +index?+, +excluded?+). Paths and String declarations are compared as {RobotsPath.path} (query dropped,
  # RFC 9309 normalization), so +/%61dmin+, +/admin?x=1+ and +/admin+ are one path.
  module PathMatch
    module_function

    # @param value [String] path or absolute URL, raw or percent-encoded
    # @return [Array<String>] the normalized path and, when it differs, its fully decoded UTF-8 form
    #   (the forms a declaration Regexp is matched against)
    def variants(value)
      [RobotsPath.path(value), RobotsPath.decoded(value)].compact.uniq
    end

    # @param patterns [Array<String, Regexp>] exact paths (normalized like the candidate) or regexps
    # @param path [String]
    # @return [Boolean] a Regexp that times out ({SafeRegexp}) counts as a match: every declaration
    #   restricts publication, so failing safe means restricting
    def any?(patterns, path)
      return false if patterns.nil? || patterns.empty?

      plain = RobotsPath.path(path)
      candidates = nil
      patterns.any? do |pattern|
        if pattern.is_a?(Regexp)
          candidates ||= variants(path)
          candidates.any? { |candidate| SafeRegexp.match?(pattern, candidate, on_timeout: true) }
        else
          RobotsPath.path(pattern) == plain
        end
      end
    end
  end
end
