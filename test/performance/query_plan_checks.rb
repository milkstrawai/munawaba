require "test_helper"
require "rack/mock"

class QueryPlanEvidenceTest < ActiveSupport::TestCase
  DIRECTORY = File.expand_path("../../tmp/performance/query_plans", __dir__)

  test "query plans cover all query families without changing the scale fixture" do
    summary = read("fixture_summary")
    { "people" => 1000, "schedules" => 200, "shifts" => 100000, "notification_deliveries" => 250000,
      "audit_events" => 250000 }.each do |table, count|
      assert_operator summary.fetch("fixture").fetch(table).fetch("count").to_i, :>=, count
    end
    assert summary.fetch("unchanged_after_explain")
    names = %w[memberships_person deactivation_discovery active_override_target calendar_global calendar_schedule
               calendar_person effective_person_conflicts lifecycle_scheduled lifecycle_pausing settings_invalidation complete_conflicts_6 complete_conflicts_5700]
    names += %w[global schedule status schedule_status].map { |suffix| "delivery_history_#{suffix}" }
    names += %w[global schedule person shift actor event].map { |suffix| "activity_history_#{suffix}" }
    names.each do |name|
      plan = read(name)
      assert plan.fetch("sql").present?
      assert plan.fetch("binds").present?
      assert plan.fetch("explain").key?("Execution Time")
      assert plan.fetch("explain").fetch("Plan").key?("Shared Hit Blocks")
    end
  end

  test "ordered leaf claims are bounded for empty sparse and backlogged queues" do
    { "dispatcher" => "next_attempt_at", "pending_expiration" => "expires_at",
      "lease_recovery" => "lease_expires_at" }.each do |family, field|
      %w[none sparse over_batch].each do |skew|
        evidence = read("#{family}_#{skew}")
        assert_match(/ORDER BY #{field},id LIMIT \$2 FOR UPDATE SKIP LOCKED/, evidence.fetch("sql"))
        rows = evidence.fetch("explain").fetch("Plan").fetch("Actual Rows")
        assert_operator rows, :<=, 100
        assert_equal 0, rows if skew == "none"
        assert (1...100).cover?(rows) if skew == "sparse"
        assert_equal 100, rows if skew == "over_batch"
      end
    end
  end

  test "small and maximum conflicts use actual production SQL and do not spill to disk" do
    [6, 5700].each do |size|
      evidence = read("complete_conflicts_#{size}")
      assert_equal Munawaba::Conflicts::Finder::SQL, evidence.fetch("sql")
      assert_equal size, JSON.parse(evidence.fetch("binds").first).size
      assert_equal 0, evidence.fetch("explain").fetch("Plan").fetch("Temp Written Blocks", 0)
    end
  end

  test "index selection retains three useful operational candidates and rejects redundancy" do
    names = read("fixture_summary").fetch("index_sizes").map { |row| row.fetch("indexrelname") }
    %w[mn_deliveries_pending_due mn_deliveries_pending_expiry mn_deliveries_lease_expiry].each { |name|
      assert_includes names, name
    }
    assert_not_includes names, "mn_deliveries_schedule_unsent"
    assert_includes names, "mn_deliveries_schedule_status_history"
    %w[delivery_history_global delivery_history_schedule delivery_history_status delivery_history_schedule_status
       activity_history_global activity_history_schedule activity_history_person activity_history_shift activity_history_actor activity_history_event].each do |name|
      evidence = read(name)
      refute_match(/\bOFFSET\b/i, evidence.fetch("sql"))
      assert_operator evidence.fetch("explain").fetch("Plan").fetch("Actual Rows"), :<=, 50
    end
  end

  test "calendar evidence is the exact production request SQL with full rows and stable ordering" do
    travel_to(Time.utc(2026, 9, 5, 12)) do
      %w[global schedule person].each do |label|
        evidence = read("calendar_#{label}")
        request = evidence.fetch("captured_request")
        statements = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          next unless payload[:name] == "Munawaba::Shift Load"

          binds = payload[:binds].map do |bind|
            value = bind.respond_to?(:value_for_database) ? bind.value_for_database : bind
            value.respond_to?(:utc) ? value.utc.iso8601(6) : value
          end
          statements << [payload[:sql], binds]
        end
        begin
          response = Rack::MockRequest.new(Rails.application).get(request.fetch("path") + "?" + URI.encode_www_form(request.fetch("params")))
          assert_equal 200, response.status
          assert_equal [[evidence.fetch("sql"), evidence.fetch("binds")]], statements
          assert_match(/SELECT "munawaba_shifts"\.\*/, evidence.fetch("sql"))
          assert_match(/ORDER BY "munawaba_shifts"\."starts_at" ASC, "munawaba_shifts"\."id" ASC/,
                       evidence.fetch("sql"))
          assert_equal read("calendar_#{label}_scalar_comparison").fetch("explain").fetch("Plan").fetch("Actual Rows"),
                       evidence.fetch("explain").fetch("Plan").fetch("Actual Rows")
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
      end
    end
  end

  private

  def read(name)
    path = File.join(DIRECTORY, "#{name}.json")
    assert File.file?(path), "Missing #{name} report; run bundle exec rake performance to generate fresh query plans"
    JSON.parse(File.read(path))
  end
end
