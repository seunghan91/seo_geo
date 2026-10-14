# frozen_string_literal: true

module SeoGeo
  # The one path normalization seo_geo uses wherever a path is compared with a robots rule or a
  # declaration: robots.txt evaluation, {Publication}, {PathMatch} (noindex declarations, sitemap
  # exclusions), llms.txt link filtering and the robots.txt denied groups.
  #
  # RFC 9309 §2.2.2 (with RFC 3986 §6.2.2): rules and paths are compared in percent-encoded form.
  # - Escapes of unreserved characters are decoded (+/%61dmin+ == +/admin+).
  # - Escapes of +$+ and +*+ are decoded too (RFC 9309 §2.2.3: +/foo-%24+ matches the path +/foo-$+); the robots
  #   pattern compiler splits wildcards/anchors before normalizing, so they stay literals there.
  # - Every other escape stays encoded, upper-cased: +%2F+, +%3F+, +%23+... are not +/+, +?+, +#+.
  # - Non-ASCII bytes, controls and spaces are percent-encoded (UTF-8 octets, upper case).
  module RobotsPath
    UNRESERVED = /[A-Za-z0-9\-._~]/
    DECODED_LITERALS = %w[$ *].freeze
    private_constant :UNRESERVED, :DECODED_LITERALS

    module_function

    # @param value [String] a path, path pattern piece or request target (query kept)
    # @return [String] normalized ASCII
    def normalize(value)
      out = +""
      bytes = value.to_s.b
      index = 0
      while index < bytes.bytesize
        byte = bytes.getbyte(index)
        if byte == 0x25 && bytes[index + 1, 2].to_s.match?(/\A\h\h\z/)
          char = bytes[index + 1, 2].hex.chr
          out << (char.match?(UNRESERVED) || DECODED_LITERALS.include?(char) ? char : "%#{bytes[index + 1, 2].upcase}")
          index += 3
          next
        end
        out << (byte == 0x25 || byte <= 0x20 || byte >= 0x7F ? format("%%%02X", byte) : byte.chr)
        index += 1
      end
      out
    end

    # Request target of a path or absolute URL: scheme/authority and fragment removed, query kept, normalized.
    # This is what robots.txt rules are matched against.
    # @param value [String]
    # @return [String]
    def target(value)
      raw = value.to_s.sub(%r{\A[a-z][a-z0-9+.\-]*://[^/?#]*}i, "").sub(/#.*\z/m, "")
      raw = "/#{raw}" unless raw.start_with?("/")
      normalize(raw)
    end

    # Path of a path or absolute URL: like {.target} with the query dropped (+""+ => +"/"+). Declarations
    # ({Configuration#noindex_paths}, sitemap exclusions, +add path, index:/noindex:+) compare this.
    # @param value [String]
    # @return [String]
    def path(value)
      target(value).sub(/\?.*\z/m, "")
    end

    # The HTML page a published URL stands for: {.path}, then a +.md+ suffix mapped back through
    # {Markdown::PathSuffix.html_path} (+/secret.md?x=1+ => +/secret+, +/index.md+ => +/+). The query is
    # dropped before the suffix is looked at, so a query cannot hide it.
    # @param value [String]
    # @param markdown [Boolean] whether +.md+ URLs are served ({MarkdownOptions#enabled})
    # @return [String]
    def html_path(value, markdown: true)
      plain = path(value)
      markdown && plain.end_with?(".md") ? Markdown::PathSuffix.html_path(plain) : plain
    end

    # {.html_path} with the query kept: what robots rules see for a published URL (+/x.md?preview=1+ =>
    # +/x?preview=1+), so a query-specific +Disallow: /x?preview=1+ still applies. Declarations ignore the query
    # anyway ({.path}).
    # @param value [String]
    # @param markdown [Boolean]
    # @return [String]
    def html_target(value, markdown: true)
      query = target(value)[/\?.*\z/m]
      "#{html_path(value, markdown: markdown)}#{query}"
    end

    # Fully percent-decoded form (UTF-8) of {.path}, for user Regexps written against readable paths
    # (+%r{\A/가이드}+); nil when the bytes are not valid UTF-8.
    # @param value [String]
    # @return [String, nil]
    def decoded(value)
      text = path(value).gsub(/(?:%\h\h)+/) { |chunk| [chunk.delete("%")].pack("H*") }.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : nil
    end

    # Compiles one robots.txt path pattern: a raw +*+ is a wildcard, a raw trailing +$+ an end anchor, escaped
    # ones (+%2A+, +%24+) are literals.
    # @param pattern [String]
    # @return [Array(Regexp, Integer)] matcher over {.normalize}d targets and the length used for precedence
    def compile(pattern)
      anchored = pattern.end_with?("$")
      body = anchored ? pattern[0...-1] : pattern
      literals = body.split("*", -1).map { |part| normalize(part) }
      regex = Regexp.new("\\A#{literals.map { |part| Regexp.escape(part) }.join(".*")}#{anchored ? "\\z" : ""}")
      [regex, literals.join("*").length + (anchored ? 1 : 0)]
    end

    # RFC 9309 §2.2.2 rule choice: the longest matching pattern wins, +Allow+ wins a tie, empty patterns are
    # ignored.
    # @param rules [Array<Array(Symbol, String)>] +[:allow | :disallow, pattern]+
    # @param value [String] path or URL ({.target} is applied)
    # @return [Array(Symbol, String), nil] the deciding rule, nil when none matches
    def decide(rules, value)
      candidate = target(value)
      rules.reject { |_, pattern| pattern.to_s.empty? }
           .map { |kind, pattern| [kind, pattern, compile(pattern)] }
           .select { |_, _, (regex, _)| regex.match?(candidate) }
           .max_by { |kind, _, (_, length)| [length, kind == :allow ? 1 : 0] }
           &.first(2)
    end

    # @param allow [Array<String>]
    # @param disallow [Array<String>]
    # @param value [String]
    # @return [Boolean] true when the rules disallow +value+
    def blocked?(allow, disallow, value)
      rule = decide(allow.map { |pattern| [:allow, pattern] } + disallow.map { |pattern| [:disallow, pattern] }, value)
      !rule.nil? && rule.first == :disallow
    end
  end
end
