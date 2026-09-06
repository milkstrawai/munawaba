# Uses a disposable *_query_plans database; a full capture recreates it.
require "pg"
require "json"
require "fileutils"
require "rack/mock"
require "active_support/testing/time_helpers"
require_relative "../../lib/munawaba"
ENV["RAILS_ENV"] = "test"
require_relative "../dummy/config/environment"

url = ENV.fetch("MUNAWABA_PLAN_DATABASE_URL", "postgres://munawaba:munawaba@127.0.0.1:55432/munawaba_query_plans")
raise "Use a dedicated *_query_plans database" unless URI(url).path.end_with?("_query_plans")

calendar_only = ARGV.include?("--calendar-only")
unless calendar_only
  admin = PG.connect(url.sub(%r{/[^/]+\z}, "/postgres"))
  name = URI(url).path.delete_prefix("/")
  admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)")
  admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)}")
end
ActiveRecord::Base.establish_connection(url)
ActiveRecord::Migration.verbose = false
connection = PG.connect(url)
unless calendar_only
  ActiveRecord::MigrationContext.new([File.expand_path("../../db/migrate", __dir__)]).migrate
  connection.exec(File.read(File.join(__dir__, "query_plan_fixture.sql")))
  connection.exec("CREATE INDEX IF NOT EXISTS mn_deliveries_schedule_unsent ON munawaba_notification_deliveries (schedule_id,id) WHERE status IN ('pending','enqueued')")
end
output = File.expand_path("../../tmp/performance/query_plans", __dir__)
FileUtils.mkdir_p(output)
FileUtils.rm_f(Dir[File.join(output, "*.json")]) unless calendar_only

def checksum(connection)
  %w[people schedules schedule_memberships shifts shift_overrides notification_deliveries audit_events].to_h do |table|
    [table,
     connection.exec("SELECT count(*),sum(id),sum(hashtextextended(row_to_json(t)::text,0)::numeric) FROM munawaba_#{table} t").first]
  end
end
before = checksum(connection)
queries = {}
queries["memberships_person"] =
  [
    "SELECT s.* FROM munawaba_schedule_memberships m JOIN munawaba_schedules s ON s.id=m.schedule_id WHERE m.person_id=$1 ORDER BY s.id", [501]
  ]
queries["deactivation_discovery"] =
  ["SELECT schedule_id FROM munawaba_schedule_memberships WHERE person_id=$1 ORDER BY schedule_id", [501]]
queries["active_override_target"] =
  ["SELECT shift_id FROM munawaba_shift_overrides WHERE replacement_person_id=$1 AND ended_at IS NULL ORDER BY shift_id",
   [501]]
range = ["2026-09-01 00:00Z", "2026-10-01 00:00Z"]
calendar_requests = {}
Object.new.extend(ActiveSupport::Testing::TimeHelpers).travel_to(Time.utc(2026, 9, 5, 12)) do
  { "global" => {}, "schedule" => { schedule_id: 101 }, "person" => { person_id: 501 } }.each do |label, filters|
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_event, _start, _finish, _id, payload|
      next unless payload[:name] == "Munawaba::Shift Load"

      binds = payload[:binds].map do |bind|
        value = bind.respond_to?(:value_for_database) ? bind.value_for_database : bind
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
      captured << [payload[:sql], binds]
    end
    begin
      query = URI.encode_www_form({ view: "month", date: "2026-09-01" }.merge(filters))
      response = Rack::MockRequest.new(Rails.application).get("/on-call/calendar?#{query}")
      raise "Calendar capture failed with #{response.status}" unless response.status == 200
      raise "Expected exactly one main calendar SELECT" unless captured.one?

      queries["calendar_#{label}"] = captured.first
      calendar_requests["calendar_#{label}"] =
        { path: "/on-call/calendar", params: { view: "month", date: "2026-09-01" }.merge(filters),
          eager_loads: %w[schedule base_person effective_person] }
      sql, binds = captured.first
      scalar = sql.sub("tstzrange(starts_at, ends_at, '[)') && tstzrange($1, $2, '[)')",
                       "starts_at < $2 AND ends_at > $1")
      raise "Expected the production range predicate" if scalar == sql

      queries["calendar_#{label}_scalar_comparison"] = [scalar, binds]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end
end
conflict = "SELECT id,schedule_id,effective_person_id,starts_at,ends_at FROM munawaba_shifts WHERE canceled_at IS NULL AND tstzrange(starts_at,ends_at,'[)') && tstzrange($1::timestamptz,$2::timestamptz,'[)')"
queries["effective_person_conflicts"] =
  [conflict + " AND effective_person_id=$3 AND schedule_id<>$4", range + [501, 100]]
%w[scheduled pausing].each do |state|
  field = state == "scheduled" ? "coverage_starts_at" : "pause_effective_at"
  queries["lifecycle_#{state}"] =
    ["SELECT id FROM munawaba_schedules WHERE state='#{state}' AND #{field}<=$1 ORDER BY #{field},id LIMIT $2",
     ["2026-09-05 12:00Z", 100]]
end
{
  "dispatcher" => ["next_attempt_at", "status='pending'"],
  "pending_expiration" => ["expires_at", "status='pending'"],
  "lease_recovery" => ["lease_expires_at", "status IN ('enqueued','processing')"]
}.each do |label, (field, predicate)|
  %w[none sparse over_batch].zip(["2026-09-05 11:00Z", "2026-09-05 11:43:20Z", "2026-09-05 13:00Z"]).each do |skew, now|
    now = (Time.parse(connection.exec("SELECT min(#{field}) FROM munawaba_notification_deliveries WHERE #{predicate}").getvalue(
                        0, 0
                      )) + 2).utc.iso8601(6) if skew == "sparse"
    queries["#{label}_#{skew}"] =
      [
        "SELECT id FROM munawaba_notification_deliveries WHERE #{predicate} AND #{field}<=$1 ORDER BY #{field},id LIMIT $2 FOR UPDATE SKIP LOCKED", [
          now, 100
        ]
      ]
  end
end
queries["settings_invalidation"] =
  [
    "SELECT id FROM munawaba_notification_deliveries WHERE schedule_id=$1 AND status IN ('pending','enqueued') AND notification_revision<$2 ORDER BY id FOR NO KEY UPDATE", [
      1, 2
    ]
  ]
{
  "global" => ["",
               []], "schedule" => ["schedule_id=$3 AND ", [101]], "status" => ["status=$3 AND ", ["failed"]], "schedule_status" => ["schedule_id=$3 AND status=$4 AND ", [151, "failed"]]
}.each do |label, (predicate, binds)|
  queries["delivery_history_#{label}"] =
    [
      "SELECT id,kind,status,created_at FROM munawaba_notification_deliveries WHERE #{predicate}(created_at,id)<($1::timestamptz,$2::bigint) ORDER BY created_at DESC,id DESC LIMIT 50", [
        "2026-08-01 00:00Z", 250001
      ] + binds
    ]
end
{
  "global" => ["",
               []], "schedule" => ["schedule_id=$3 AND ", [101]], "person" => ["person_id=$3 AND ", [501]], "shift" => ["shift_id=$3 AND ", [501]], "actor" => ["actor_type=$3 AND actor_id=$4 AND ", ["User", "1"]], "event" => ["event_type=$3 AND ", ["person.created"]]
}.each do |label, (predicate, binds)|
  queries["activity_history_#{label}"] =
    [
      "SELECT id,event_type,occurred_at FROM munawaba_audit_events WHERE #{predicate}(occurred_at,id)<($1::timestamptz,$2::bigint) ORDER BY occurred_at DESC,id DESC LIMIT 50", [
        "2026-08-01 00:00Z", 250001
      ] + binds
    ]
end
[6, 5700].each do |count|
  slots = count.times.map do |i|
    { target_schedule_id: (i / 57) + 1, target_shift_id: nil, coverage_revision: 2, boundary_index: 450 + (i % 57),
      effective_person_id: (i % 1000) + 1, starts_at: (Time.utc(2026, 9, 5) + ((i % 57) * 604800)).iso8601(6), ends_at: (Time.utc(2026, 9, 5) + (((i % 57) + 1) * 604800)).iso8601(6) }
  end
  queries["complete_conflicts_#{count}"] = [Munawaba::Conflicts::Finder::SQL, [JSON.generate(slots)]]
end
queries.select! { |name, _| name.start_with?("calendar_") } if calendar_only
results = {}
queries.each do |label, (sql, binds)|
  connection.exec("BEGIN")
  begin
    plan = JSON.parse(connection.exec_params("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql, binds).getvalue(0,
                                                                                                               0)).first
    results[label] = { sql: sql, binds: binds, explain: plan }
    results[label][:captured_request] = calendar_requests[label] if calendar_requests.key?(label)
    File.write(File.join(output, "#{label}.json"), JSON.pretty_generate(results[label]) + "\n")
    puts "#{label}: #{plan["Execution Time"]} ms, #{plan.dig("Plan",
                                                             "Actual Rows")} rows, #{plan.dig("Plan",
                                                                                              "Shared Hit Blocks")} hit blocks"
  ensure
    connection.exec("ROLLBACK")
  end
end
%w[global schedule person].each do |label|
  main = results.fetch("calendar_#{label}")
  scalar = results.fetch("calendar_#{label}_scalar_comparison")
  main_ids = connection.exec_params(main[:sql], main[:binds]).column_values(0)
  scalar_ids = connection.exec_params(scalar[:sql], scalar[:binds]).column_values(0)
  raise "Calendar #{label} changed result IDs or ordering" unless main_ids == scalar_ids
end
if calendar_only
  raise "Fixture changed during calendar EXPLAIN" unless before == checksum(connection)

  summary = JSON.parse(File.read(File.join(output, "fixture_summary.json")))
  summary["calendar_recapture"] =
    { "at" => Time.now.utc.iso8601(6), "unchanged_after_explain" => true, "equal_scalar_and_range_ordered_ids" => true }
  File.write(File.join(output, "fixture_summary.json"), JSON.pretty_generate(summary) + "\n")
  exit
end
indexes = { "mn_deliveries_pending_due" => "dispatcher_none", "mn_deliveries_pending_expiry" => "pending_expiration_none",
            "mn_deliveries_lease_expiry" => "lease_recovery_none", "mn_deliveries_schedule_unsent" => "settings_invalidation" }
indexes.each do |index, label|
  sql, binds = queries.fetch(label)
  connection.exec("BEGIN")
  begin
    connection.exec("DROP INDEX #{index}")
    plan = JSON.parse(connection.exec_params("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql, binds).getvalue(0,
                                                                                                               0)).first
    File.write(File.join(output, "without_#{index}.json"),
               JSON.pretty_generate({ sql: sql, binds: binds, explain: plan }) + "\n")
  ensure
    connection.exec("ROLLBACK")
  end
end
# Verify that the existing schedule/status history index also supports invalidation.
connection.exec("DROP INDEX mn_deliveries_schedule_unsent")
sql, binds = queries.fetch("settings_invalidation")
connection.exec("BEGIN")
begin
  plan = JSON.parse(connection.exec_params("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql, binds).getvalue(0,
                                                                                                             0)).first
  results["settings_invalidation"] = { sql: sql, binds: binds, explain: plan }
  File.write(File.join(output, "settings_invalidation.json"),
             JSON.pretty_generate(results["settings_invalidation"]) + "\n")
ensure
  connection.exec("ROLLBACK")
end
raise "Fixture changed during EXPLAIN" unless before == checksum(connection)

summary = { postgresql: connection.exec("SELECT version()").getvalue(0, 0), fixture: before, unchanged_after_explain: true,
            index_sizes: connection.exec("SELECT indexrelname,pg_relation_size(indexrelid) AS bytes FROM pg_stat_user_indexes WHERE schemaname='public' ORDER BY indexrelname").to_a }
File.write(File.join(output, "fixture_summary.json"), JSON.pretty_generate(summary) + "\n")
