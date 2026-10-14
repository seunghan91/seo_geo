# frozen_string_literal: true

module SeoGeo
  # Matches configuration Regexps (+og_image.param_constraints+, +noindex_paths+, +sitemap.exclude+) against
  # request-controlled strings with a per-regexp timeout, so a backtracking pattern such as
  # +/\A(a+)+\1\z/+ cannot hold a request worker. +Regexp.timeout+ is nil by default (Rails 7.2 included).
  #
  # Callers choose what a timeout means; seo_geo always resolves it to the restrictive answer
  # (OG param => 400, noindex path => noindex, exclusion => excluded).
  module SafeRegexp
    # Seconds a single match may run.
    TIMEOUT = 0.05
    # Longer input is never handed to a configuration Regexp.
    MAX_INPUT = 4096

    # Raised (and only raised) for the input-length cap; Regexp::TimeoutError covers slow matches.
    class TooLong < StandardError; end

    @cache = {}
    @lock = Mutex.new

    module_function

    # @param regexp [Regexp]
    # @param string [String]
    # @raise [Regexp::TimeoutError, TooLong]
    # @return [MatchData, nil]
    def match(regexp, string)
      raise TooLong, "input longer than #{MAX_INPUT} characters" if string.length > MAX_INPUT

      bounded(regexp).match(string)
    end

    # @param regexp [Regexp]
    # @param string [String]
    # @param on_timeout [Boolean] answer when the match times out or the input is too long
    # @return [Boolean]
    def match?(regexp, string, on_timeout:)
      !match(regexp, string).nil?
    rescue Regexp::TimeoutError, TooLong
      on_timeout
    end

    # @return [Regexp] a copy of +regexp+ carrying {TIMEOUT}, cached per source and options
    def bounded(regexp)
      key = [regexp.source, regexp.options]
      @lock.synchronize { @cache[key] ||= Regexp.new(regexp.source, regexp.options, timeout: TIMEOUT) }
    end
  end
end
