# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

# Every code example in README.md and AGENTS.md is a file under docs/examples/ and runs here (P7).
#
# Markers (HTML comments, invisible on GitHub) on the line before a fenced block:
# - <!-- example: <app>/<path> -->         the block is byte-for-byte docs/examples/<app>/<path>
# - <!-- output: <app> GET <path> Name=value ... -->  every non-blank line of the block appears (stripped) in that
#   response's headers ("name: value") or body, from the app booted in production
# - <!-- output: <app> audit env=<env> --> every line appears in `rake seo_geo:audit` stdout/stderr (exit status 0),
#   booted the way `bin/rails seo_geo:audit` boots it in that environment
# - <!-- curl: <app> -->                   every `curl` line is replayed against the app; it must answer 200, or
#   the status named by a trailing `# => 404`
# Ruby, ERB, YAML and JS blocks without an example marker fail the test: nothing reaches the docs unexecuted.
class DocExamplesTest < Minitest::Test
  GEM_ROOT = File.expand_path("../..", __dir__)
  EXAMPLES = File.join(GEM_ROOT, "docs/examples")
  DOCS = %w[README.md AGENTS.md].freeze
  # Directories copied (in order) into one app root.
  APPS = { "quickstart" => %w[quickstart], "inertia" => %w[quickstart inertia] }.freeze
  CODE_LANGS = %w[ruby rb erb yaml yml js javascript].freeze

  Block = Struct.new(:doc, :line, :lang, :marker, :body, keyword_init: true)

  def self.blocks
    @blocks ||= DOCS.flat_map do |doc|
      lines = File.readlines(File.join(GEM_ROOT, doc), chomp: true)
      found = []
      index = 0
      while index < lines.size
        if (fence = lines[index][/\A```(\w*)\z/, 1])
          close = (index + 1...lines.size).find { |i| lines[i] == "```" } or raise "#{doc}:#{index + 1}: unclosed fence"
          marker = index.positive? ? lines[index - 1][/\A<!-- (.+) -->\z/, 1] : nil
          found << Block.new(doc: doc, line: index + 1, lang: fence, marker: marker,
                             body: lines[(index + 1)...close].join("\n") + "\n")
          index = close
        end
        index += 1
      end
      found
    end
  end

  # One boot per app and mode for the whole file; results are memoized by the class.
  def self.app_root(app)
    @roots ||= {}
    @roots[app] ||= Dir.mktmpdir("seo_geo_doc_#{app}").tap do |root|
      APPS.fetch(app).each { |dir| FileUtils.cp_r("#{File.join(EXAMPLES, dir)}/.", root) }
      Minitest.after_run { FileUtils.remove_entry(root) }
    end
  end

  def self.run_app(app, mode, stdin: "", env: "production")
    Open3.capture3({ "RAILS_ENV" => env }, RbConfig.ruby, "-I#{GEM_ROOT}/lib", "-I#{GEM_ROOT}/test",
                   "#{GEM_ROOT}/test/docs/support/example_app.rb", mode, app_root(app), stdin_data: stdin, chdir: GEM_ROOT)
  end

  # @return [Hash{Array => Hash}] request key => {"status", "headers", "body"} for every request the docs make
  def self.responses
    @responses ||= requests_by_app.to_h do |app, requests|
      out, err, status = run_app(app, "requests", stdin: JSON.generate(requests))
      raise "#{app} example app failed:\n#{err}" unless status.success?

      [app, requests.zip(JSON.parse(out)).to_h { |request, response| [request, response] }]
    end
  end

  def self.requests_by_app
    requests = Hash.new { |hash, key| hash[key] = [] }
    blocks.each do |block|
      case block.marker
      when /\Aoutput: (\S+) GET (\S+)(.*)\z/ then requests[$1] << request_from_marker($2, $3)
      when /\Acurl: (\S+)\z/ then curl_lines(block).each { |curl| requests[$1] << curl[:request] }
      end
    end
    requests.transform_values(&:uniq)
  end

  def self.request_from_marker(path, rest)
    { "method" => "GET", "path" => path, "headers" => rest.split.to_h { |pair| pair.split("=", 2) } }
  end

  # @return [Array<Hash>] {request:, expected_status:, line:} per `curl` command
  def self.curl_lines(block)
    block.body.lines.filter_map do |line|
      command, comment = line.split(" #", 2)
      next unless command.strip.start_with?("curl ")

      words = Shellwords.split(command)
      headers = words.each_cons(2).select { |flag, _| flag == "-H" }.to_h { |_, value| value.split(": ", 2) }
      url = words.find { |word| word.start_with?("http://", "https://") }
      { request: { "method" => "GET", "path" => URI(url).request_uri, "headers" => headers },
        expected_status: comment.to_s[/=> (\d{3})/, 1]&.to_i || 200, line: line.strip }
    end
  end

  def blocks_with(pattern)
    self.class.blocks.select { |block| block.marker&.match?(pattern) }
  end

  def test_every_code_block_is_an_executed_example
    unmarked = self.class.blocks.select { |block| CODE_LANGS.include?(block.lang) && !block.marker&.start_with?("example: ") }
    assert_empty unmarked.map { |block| "#{block.doc}:#{block.line}" }, "code blocks without an <!-- example: --> marker"
    assert_operator blocks_with(/\Aexample: /).size, :>=, 10
  end

  def test_example_blocks_match_their_files
    blocks_with(/\Aexample: /).each do |block|
      path = File.join(EXAMPLES, block.marker.delete_prefix("example: "))
      assert File.file?(path), "#{block.doc}:#{block.line}: #{path} does not exist"
      assert_equal File.read(path), block.body, "#{block.doc}:#{block.line} differs from #{path}"
    end
  end

  def test_output_blocks_appear_in_responses
    blocks_with(/\Aoutput: \S+ GET /).each do |block|
      app, path, rest = block.marker.match(/\Aoutput: (\S+) GET (\S+)(.*)\z/).captures
      response = self.class.responses.fetch(app).fetch(self.class.request_from_marker(path, rest))
      assert_equal 200, response["status"], "#{block.doc}:#{block.line}"
      lines = response["headers"].map { |name, value| "#{name}: #{value}" } + response["body"].lines.map(&:strip)
      block.body.lines.map(&:strip).reject(&:empty?).each do |expected|
        assert_includes lines, expected, "#{block.doc}:#{block.line}: #{app} GET #{path}#{rest} does not contain this line"
      end
    end
  end

  def test_curl_commands_answer
    blocks = blocks_with(/\Acurl: /)
    refute_empty blocks
    blocks.each do |block|
      app = block.marker.delete_prefix("curl: ")
      self.class.curl_lines(block).each do |curl|
        response = self.class.responses.fetch(app).fetch(curl[:request])
        assert_equal curl[:expected_status], response["status"], "#{block.doc}:#{block.line}: #{curl[:line]}"
      end
    end
  end

  def test_audit_output
    blocks = blocks_with(/\Aoutput: \S+ audit env=\w+\z/)
    refute_empty blocks
    blocks.each do |block|
      app, env = block.marker.match(/\Aoutput: (\S+) audit env=(\w+)\z/).captures
      out, err, status = self.class.run_app(app, "audit", env: env)
      assert status.success?, "audit failed:\n#{out}\n#{err}"
      printed = (out.lines + err.lines).map(&:strip)
      block.body.lines.map(&:strip).reject(&:empty?).each { |line| assert_includes printed, line, "#{block.doc}:#{block.line}" }
    end
  end

  # The Gemfile line names this gem.
  def test_gemfile_example_names_this_gem
    spec = Gem::Specification.load(File.join(GEM_ROOT, "seo_geo.gemspec"))
    assert_includes File.read(File.join(EXAMPLES, "install/Gemfile")), %(gem "#{spec.name}")
  end

  # The Minitest example in AGENTS.md (docs/examples/quickstart/test/) passes against the quickstart app.
  def test_minitest_example_passes
    out, err, status = self.class.run_app("quickstart", "minitest", env: "test")
    assert status.success?, "#{out}\n#{err}"
    assert_match(/3 runs, \d+ assertions, 0 failures, 0 errors/, out)
  end

  # The Inertia entrypoint line really reaches the head snippet's window.SeoGeo.mounted().
  def test_inertia_mounted_call_runs_against_the_head_snippet
    node = ENV.fetch("NODE", "node")
    skip "node is not installed" unless system(node, "--version", out: File::NULL, err: File::NULL)

    body = self.class.responses.fetch("inertia").fetch(self.class.request_from_marker("/", " Host=www.example.com"))["body"]
    snippet = body[%r{<script>(\(function\(w,d\).*?)</script>}m, 1]
    refute_nil snippet, "head has no crawler-fallback snippet"
    entry = File.read(File.join(EXAMPLES, "inertia/app/frontend/entrypoints/application.js"))
    script = <<~JS
      const classes = new Set();
      const document = { documentElement: { classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) } } };
      const window = {};
      globalThis.setTimeout = () => {};
      #{snippet}
      #{entry}
      console.log([...classes].sort().join(","));
    JS
    out, err, status = Open3.capture3(node, "-e", script)
    assert status.success?, err
    assert_equal "seo-geo-js,seo-geo-mounted", out.strip
  end
end
