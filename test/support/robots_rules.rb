# frozen_string_literal: true

# Minimal RFC 9309 evaluator for tests: a crawler obeys the groups naming its token (merged), else "*";
# inside the chosen rules the longest matching path wins and Allow wins a tie. No wildcards ("*", "$").
class RobotsRules
  Group = Struct.new(:agents, :rules)

  def initialize(body)
    @groups = []
    current = nil
    body.each_line do |raw|
      line = raw.sub(/#.*/, "").strip
      next if line.empty?

      field, value = line.split(":", 2).map(&:strip)
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

  # @return [Boolean]
  def allowed?(user_agent, path)
    rules = rules_for(user_agent.downcase)
    best = rules.reject { |_, prefix| prefix.empty? }.select { |_, prefix| path.start_with?(prefix) }
                .max_by { |kind, prefix| [prefix.length, kind == :allow ? 1 : 0] }
    best.nil? || best.first == :allow
  end

  # @return [Array<String>] every agent token that has its own group
  def agents
    @groups.flat_map(&:agents)
  end

  private

  def rules_for(token)
    named = @groups.select { |group| group.agents.include?(token) }
    named = @groups.select { |group| group.agents.include?("*") } if named.empty?
    named.flat_map(&:rules)
  end
end
