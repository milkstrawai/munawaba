# frozen_string_literal: true

require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"
require "rubocop/rake_task"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.libs << "lib"
  task.pattern = "test/**/*_test.rb"
  task.warning = false
end

desc "Check fresh query plans and HTTP/job performance budgets"
task :performance do
  ruby "test/database/capture_query_plans.rb"
  ruby "-Itest", "test/performance/query_plan_checks.rb"
  ruby "test/performance/http_benchmarks.rb"
  ruby "test/performance/job_benchmarks.rb"
end

RuboCop::RakeTask.new do |task|
  task.options = ["--no-server"]
end

task default: %i[test rubocop]
