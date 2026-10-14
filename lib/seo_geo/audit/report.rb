# frozen_string_literal: true

require "json"

module SeoGeo
  module Audit
    SEVERITIES = %i[error warning].freeze

    # One problem.
    #
    # @!attribute severity [Symbol] :error (exit non-zero) or :warning
    # @!attribute check [String] check id, e.g. "title.count"
    # @!attribute host [String, nil]
    # @!attribute url [String, nil] URL or file:line
    # @!attribute message [String]
    Finding = Data.define(:severity, :check, :host, :url, :message) do
      # @return [Hash{String => String}]
      def to_h
        { "severity" => severity.to_s, "check" => check, "host" => host, "url" => url, "message" => message }
      end
    end

    # Collected findings plus counters. +to_s+ for people, +to_json+ for CI.
    class Report
      # @return [Array<Finding>]
      attr_reader :findings
      # @return [Hash{String => Integer}] e.g. "pages" => 12
      attr_reader :stats

      def initialize
        @findings = []
        @stats = Hash.new(0)
      end

      # @param severity [Symbol] :error or :warning
      # @param check [String]
      # @param message [String]
      # @param host [String, nil]
      # @param url [String, nil]
      # @return [Finding]
      def add(severity, check, message, host: nil, url: nil)
        raise ArgumentError, "unknown severity #{severity.inspect}" unless SEVERITIES.include?(severity)

        Finding.new(severity: severity, check: check, host: host, url: url, message: message).tap { |item| @findings << item }
      end

      # @return [Array<Finding>]
      def errors
        findings.select { |item| item.severity == :error }
      end

      # @return [Array<Finding>]
      def warnings
        findings.select { |item| item.severity == :warning }
      end

      # @return [Boolean]
      def errors?
        !errors.empty?
      end

      # @return [Hash]
      def to_h
        { "errors" => errors.size, "warnings" => warnings.size, "stats" => stats.dup,
          "findings" => findings.map(&:to_h) }
      end

      # @return [String]
      def to_json(*args)
        JSON.pretty_generate(to_h, *args)
      end

      # @return [String] one line per finding, then a summary line
      def to_s
        lines = findings.sort_by { |item| [SEVERITIES.index(item.severity), item.host.to_s, item.check] }.map do |item|
          where = [item.host, item.url].compact.join(" ")
          "#{item.severity.to_s.upcase.ljust(7)} #{item.check.ljust(22)} #{where}#{where.empty? ? "" : " — "}#{item.message}"
        end
        counted = stats.map { |name, count| "#{count} #{name}" }.join(", ")
        lines << "seo_geo audit: #{errors.size} error(s), #{warnings.size} warning(s)#{counted.empty? ? "" : " (#{counted})"}"
        "#{lines.join("\n")}\n"
      end
    end
  end
end
