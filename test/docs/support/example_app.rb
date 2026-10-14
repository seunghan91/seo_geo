# frozen_string_literal: true

# Boots one docs example (docs/examples/<name>/, copied into ROOT by test/docs/doc_examples_test.rb) as a fresh
# Rails application in its own process and reports what it serves.
#   ruby -Ilib -Itest test/docs/support/example_app.rb MODE ROOT
# MODE "requests": reads [{"method", "path", "headers"}] as JSON on stdin, prints [{"status", "headers", "body"}].
# MODE "audit": runs `rake seo_geo:audit` the way bin/rails does (exit status and output are the task's).
# MODE "minitest": runs ROOT/test/**/*_test.rb with Minitest.
# RAILS_ENV picks the environment.
mode, root = ARGV
require "json"
require "support/dummy_base"

# A stand-in for inertia_rails' renderer: the page object goes into an empty <div id="app" data-page>, rendered
# inside the application layout (what `render inertia:` does on a first, non-XHR visit).
ActionController::Renderers.add :inertia do |component, options|
  page = { component: component, props: options[:props] || {}, url: request.fullpath }
  html = view_context.tag.div(id: "app", data: { page: page.to_json })
  self.content_type = "text/html"
  render_to_string(html: html, layout: "application")
end

app_controller = File.join(root, "app/controllers/application_controller.rb")
File.write(app_controller, "class ApplicationController < ActionController::Base\nend\n") unless File.exist?(app_controller)

class ExampleApp < Rails::Application; end
SeoGeoDummyBase.apply(ExampleApp, root: root)
# Rails' development default, so the audit has to open config.hosts for the configured hosts itself.
ExampleApp.config.hosts << ".localhost" if ENV["RAILS_ENV"] == "development"
if mode == "audit"
  # Like `bin/rails seo_geo:audit`: tasks load first, the :environment prerequisite boots the app.
  File.write(File.join(root, "config/environment.rb"), "Rails.application.initialize!\n")
else
  Rails.application.initialize!
end

case mode
when "requests"
  require "rack/mock"
  results = JSON.parse($stdin.read).map do |request|
    env = Rack::MockRequest.env_for("https://#{request.fetch("headers", {}).fetch("Host", "www.example.com")}#{request["path"]}",
                                    method: request.fetch("method", "GET"))
    env["HTTPS"] = "on"
    request.fetch("headers", {}).each { |name, value| env["HTTP_#{name.upcase.tr("-", "_")}"] = value }
    status, headers, body = Rails.application.call(env)
    text = +""
    body.each { |part| text << part }
    body.close if body.respond_to?(:close)
    { status: status, headers: headers.to_h { |name, value| [name.downcase, value] }, body: text }
  end
  puts JSON.generate(results)
when "audit"
  Rails.application.load_tasks
  Rake::Task["seo_geo:audit"].invoke
when "minitest"
  ENV["SEO_GEO_EXAMPLE_TEST"] = "1"
  require "rails/test_help"
  $LOAD_PATH.unshift(File.join(root, "test"))
  File.write(File.join(root, "test/test_helper.rb"), "") unless File.exist?(File.join(root, "test/test_helper.rb"))
  Dir[File.join(root, "test/**/*_test.rb")].each { |file| require file }
else
  abort "unknown mode #{mode.inspect}"
end
