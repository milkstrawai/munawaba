# frozen_string_literal: true

# Run after test/database/capture_query_plans.rb. Uses only its disposable fixture.
ENV["RAILS_ENV"] = "test"
require_relative "../dummy/config/environment"
require "active_support/testing/time_helpers"
require "action_dispatch/testing/integration"
require "json"
require "fileutils"
include ActiveSupport::Testing::TimeHelpers

url = ENV.fetch("MUNAWABA_PLAN_DATABASE_URL", "postgres://munawaba:munawaba@127.0.0.1:55432/munawaba_query_plans")
raise "Use the dedicated *_query_plans fixture database" unless URI(url).path.end_with?("_query_plans")

ActiveRecord::Base.establish_connection(url)
Rails.application.eager_load!
travel_to Time.utc(2026, 9, 5, 12)
session = ActionDispatch::Integration::Session.new(Rails.application)
session.host! "www.example.com"

def fixture_checksum
  %w[people schedules schedule_memberships shifts shift_overrides notification_deliveries audit_events].to_h do |table|
    [table,
     ActiveRecord::Base.connection.select_one("SELECT count(*), sum(id), sum(hashtextextended(row_to_json(t)::text,0)::numeric) FROM munawaba_#{table} t")]
  end
end
before = fixture_checksum

def measure(session, path, params = {})
  queries = []
  subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
    queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
  end
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  session.get(path, params: params, headers: { "Accept" => "text/html" })
  elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  raise "#{path}: HTTP #{session.response.status}" unless session.response.status == 200
  raise "Calendar omitted overflow shifts" if params[:view] == "month" && !session.response.body.include?("more shifts")

  { milliseconds: elapsed.round(3), queries: queries.size, response_bytes: session.response.body.bytesize,
    uses_offset: queries.any? { |sql| sql.match?(/\bOFFSET\b/i) } }
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
end

cases = {
  overview: ["/on-call"],
  calendar_month: ["/on-call/calendar", { view: "month", date: "2026-09-01" }],
  activity_first: ["/on-call/activity"],
  activity_deep: ["/on-call/activity", { before: "2026-04-01T00:00:00.000000Z|250001" }],
  deliveries_first: ["/on-call/notification_deliveries"],
  deliveries_deep: ["/on-call/notification_deliveries", { before: "2026-04-01T00:00:00.000000Z|250001" }]
}
results = cases.to_h do |label, (path, params)|
  measure(session, path, params || {})
  samples = 5.times.map { measure(session, path, params || {}) }
  summary = { median_ms: samples.map { |s| s[:milliseconds] }.sort[2], max_ms: samples.map { |s| s[:milliseconds] }.max,
              query_count: samples.map { |s| s[:queries] }.uniq, response_bytes: samples.first[:response_bytes],
              uses_offset: samples.any? { |s| s[:uses_offset] }, samples: samples }
  puts "#{label}: median #{summary[:median_ms]} ms, max #{summary[:max_ms]} ms, #{summary[:query_count].join("/")} queries"
  [label, summary]
end
output = { ruby: RUBY_VERSION, rails: Rails.version, postgresql: ActiveRecord::Base.connection.select_value("SHOW server_version"),
           fixture: { people: Munawaba::Person.count, schedules: Munawaba::Schedule.count, shifts: Munawaba::Shift.count,
                      deliveries: Munawaba::NotificationDelivery.count, activity: Munawaba::AuditEvent.count }, results: results,
           unchanged_after_requests: before == fixture_checksum,
           budgets: { calendar_median_ms: 900, overview_median_ms: 400, history_median_ms: 150, overview_queries: 5, calendar_queries: 6, history_queries: 3 } }
directory = File.expand_path("../../tmp/performance", __dir__)
FileUtils.mkdir_p(directory)
File.write(File.join(directory, "http-benchmarks.json"), JSON.pretty_generate(output) + "\n")
raise "Read requests changed the fixture" unless output[:unchanged_after_requests]
raise "Fixture is below release scale" unless output[:fixture].values.zip([1000, 200, 100000, 250000, 250000]).all? { |actual, minimum| actual >= minimum }

results.each do |label, result|
  budget = label == :calendar_month ? 900 : label == :overview ? 400 : 150
  query_budget = label == :calendar_month ? 6 : label == :overview ? 5 : 3
  raise "#{label} exceeds #{budget} ms median budget" unless result[:median_ms] < budget
  raise "#{label} exceeds #{query_budget} queries" unless result[:query_count].all? { |count| count <= query_budget }
  raise "#{label} uses OFFSET" if result[:uses_offset]
end
%w[activity deliveries].each do |kind|
  raise "#{kind} deep pagination degraded" if results.fetch(:"#{kind}_deep")[:median_ms] > (results.fetch(:"#{kind}_first")[:median_ms] * 3) + 10
end
travel_back
