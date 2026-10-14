# frozen_string_literal: true

module SeoGeo
  class Robots
    # Reads a robots.txt body and answers "may this crawler fetch this path?" the way RFC 9309 says a
    # crawler decides. Used by the test helpers and
    # +rake seo_geo:audit+; it is never used for access decisions at request time.
    #
    # - Group choice (§2.2.1): the groups naming the crawler's product token (case-insensitive) are merged;
    #   only when none names it does the crawler fall back to the +*+ groups.
    # - Rule choice (§2.2.2): the longest matching path wins; +Allow+ wins a tie; no matching rule => allowed.
    # - Patterns: +*+ matches any sequence, a trailing +$+ anchors the end. An empty +Disallow:+ is ignored.
    #   Rules and paths are compared in {RobotsPath.normalize}d form: +/%61dmin+ is +/admin+, but an encoded
    #   reserved delimiter stays one (+/download%3Fpublic+ is not +/download?public+).
    #
    # @example
    #   rules = SeoGeo::Robots::Evaluator.new(body)
    #   rules.allowed?("GPTBot", "/admin")                       # => false
    #   rules.allowed?("Mozilla/5.0 (compatible; GPTBot/1.2)", "/") # full User-Agent headers work too
    class Evaluator
      Group = Struct.new(:agents, :rules)

      # @param body [String] robots.txt contents
      def initialize(body)
        @groups = []
        current = nil
        body.to_s.each_line do |raw|
          line = raw.sub(/#.*/, "").strip
          next if line.empty?

          field, value = line.split(":", 2).map { |part| part.to_s.strip }
          case field.downcase
          when "user-agent"
            current = nil if current && !current.rules.empty?
            current ||= Group.new([], []).tap { |group| @groups << group }
            current.agents << value.downcase
          when "allow", "disallow"
            current&.rules&.push([field.downcase.to_sym, value])
          end
        end
      end

      # @param user_agent [String] robots.txt product token ("GPTBot", "*") or a full User-Agent header
      # @param path [String] path, optionally with a query string
      # @return [Boolean]
      def allowed?(user_agent, path)
        rule = matching_rule(user_agent, path)
        rule.nil? || rule.first == :allow
      end

      # @param user_agent [String]
      # @param path [String]
      # @return [Array(Symbol, String), nil] the deciding +[:allow | :disallow, pattern]+, nil when no rule matches
      def matching_rule(user_agent, path)
        RobotsPath.decide(rules_for(user_agent), path.to_s.empty? ? "/" : path.to_s)
      end

      # @return [Array<String>] every agent token that has a group (lower case)
      def agents
        @groups.flat_map(&:agents)
      end

      # @param user_agent [String]
      # @return [String] the group token the crawler obeys ("*" when no group names it)
      def group_token(user_agent)
        token_for(user_agent.to_s.downcase) || "*"
      end

      private

      def rules_for(user_agent)
        token = group_token(user_agent)
        @groups.select { |group| group.agents.include?(token) }.flat_map(&:rules)
      end

      # Exact token first; otherwise the longest group token contained in a full User-Agent header.
      def token_for(needle)
        named = agents.uniq - ["*"]
        return needle if named.include?(needle)

        named.select { |token| needle.include?(token) }.max_by(&:length)
      end
    end
  end
end
