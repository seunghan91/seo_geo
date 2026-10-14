# frozen_string_literal: true

require "rake/testtask"

# Unit tests never boot a Rails application.
Rake::TestTask.new("test:unit") do |task|
  task.libs << "test"
  task.pattern = "test/unit/**/*_test.rb"
end

# Docs tests: README/AGENTS code blocks against docs/examples/ apps, each booted in a subprocess.
Rake::TestTask.new("test:docs") do |task|
  task.libs << "test"
  task.pattern = "test/docs/**/*_test.rb"
end

# App tests boot one dummy application per process; SEO_GEO_DUMMY selects it.
Rake::TestTask.new("test:app_run") do |task|
  task.libs << "test"
  task.pattern = "test/app/**/*_test.rb"
end

namespace :test do
  desc "Run app tests against the ERB dummy (test/dummy)"
  task :erb do
    ENV["SEO_GEO_DUMMY"] = "dummy"
    Rake::Task["test:app_run"].reenable
    Rake::Task["test:app_run"].invoke
  end

  desc "Run app tests against the Inertia-like dummy (test/dummy_inertia)"
  task :inertia do
    ENV["SEO_GEO_DUMMY"] = "dummy_inertia"
    Rake::Task["test:app_run"].reenable
    Rake::Task["test:app_run"].invoke
  end
end

desc "Run unit tests, docs example tests and app tests against both dummy applications"
task test: ["test:unit", "test:docs", "test:erb", "test:inertia"]
task default: :test
