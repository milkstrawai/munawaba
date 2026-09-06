require "test_helper"

class SchemaContractTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 9, 5, 12)
    @person = Munawaba::Person.create!(name: "Ada", email: "ada@example.org")
    @other = Munawaba::Person.create!(name: "Grace", email: "grace@example.org")
    @schedule = Munawaba::Schedule.create!(name: "Primary", cadence: "one_week", time_zone: "UTC",
                                           anchor_local_date: @now.to_date, anchor_local_seconds: 0)
    @shift = Munawaba::Shift.create!(schedule: @schedule, coverage_revision: 1, boundary_index: 0, starts_at: @now,
                                     ends_at: @now + 1.week, base_person: @person, effective_person: @person, generated_at: @now)
    @valid = {
      "people" => { name: "Person", email: "new@example.org", active: true, lock_version: 0 },
      "schedules" => { name: "Another", state: "draft", cadence: "one_week", time_zone: "UTC",
                       anchor_local_date: @now.to_date, anchor_local_seconds: 0, coverage_revision: 0, rotation_revision: 0, lifecycle_revision: 0, notification_revision: 0, slack_enabled: false, notify_advance: true, advance_notice_seconds: 86400, notify_shift_start: true, notify_assignment_change: true, notify_next_assignment_change: true, lock_version: 0 },
      "schedule_memberships" => { schedule_id: @schedule.id, person_id: @person.id, position: 0 },
      "shifts" => { schedule_id: @schedule.id, coverage_revision: 1, boundary_index: 1, starts_at: @now + 1.week,
                    ends_at: @now + 2.weeks, base_person_id: @person.id, effective_person_id: @person.id, rotation_revision: 0, assignment_version: 1, timing_version: 1, generated_at: @now, lock_version: 0 },
      "shift_overrides" => { shift_id: @shift.id, previous_person_id: @person.id, replacement_person_id: @other.id },
      "notification_deliveries" => { schedule_id: @schedule.id, kind: "test", status: "pending",
                                     event_key: "test:unique", notification_revision: 0, context: { schema_version: 1 }, due_at: @now, next_attempt_at: @now, expires_at: @now + 10.minutes, attempt_count: 0 },
      "audit_events" => { operation_id: SecureRandom.uuid, event_type: "person.created", person_id: @person.id,
                          actor_type: "User", actor_id: "1", metadata: {}, occurred_at: @now }
    }.transform_values { |row| row.merge(created_at: @now, updated_at: @now) }
    @valid["audit_events"].delete(:updated_at)
  end

  test "every contractually required column independently rejects null through SQL" do
    @valid.each do |table, _attributes|
      columns = connection.columns("munawaba_#{table}").reject { |column| column.name == "id" || column.null }
      columns.each do |column|
        rejects(table, column.name.to_sym => nil)
      end
    end
  end

  test "all instants explicitly use microsecond timestamptz independently of host defaults" do
    rows = connection.select_all("SELECT table_name, column_name, data_type, datetime_precision FROM information_schema.columns WHERE table_schema = 'public' AND table_name LIKE 'munawaba_%' AND (column_name LIKE '%\\_at' ESCAPE '\\' OR column_name IN ('starts_at', 'ends_at'))")
    assert_operator rows.to_a.size, :>, 30
    rows.each do |row|
      assert_equal "timestamp with time zone", row["data_type"], row.inspect
      assert_equal 6, row["datetime_precision"], row.inspect
    end
    assert_nil(connection.columns("munawaba_audit_events").find { |column| column.name == "updated_at" })
  end

  test "people identity normalization uniqueness and state are database enforced" do
    [{ name: "" }, { name: " Ada" }, { email: "" }, { email: "UPPER@example.org" }, { email: "ada@example.org" },
     { slack_member_id: "<@ABC>" }, { slack_member_id: "A" }, { slack_member_id: "aBC" }, { active: false }, { deactivated_at: @now }, { lock_version: -1 }].each { |values|
      rejects("people", values)
    }
    insert("people", slack_member_id: "UABC")
    rejects("people", email: "different@example.org", slack_member_id: "UABC")
    assert insert("people", email: "inactive@example.org", active: false, deactivated_at: @now)
  end

  test "schedule enums ranges presence matrices and integration equivalence are enforced" do
    [{ name: "primary" }, { name: "" }, { name: " Another" }, { state: "archived" }, { cadence: "daily" },
     { time_zone: "" }, { anchor_local_seconds: -60 }, { anchor_local_seconds: 1 }, { anchor_local_seconds: 86400 }, { advance_notice_seconds: 0 }, { advance_notice_seconds: 2592001 }, { state: "active" }, { state: "scheduled" }, { state: "pausing" }, { state: "paused" }, { first_activated_at: @now }, { coverage_start_boundary: 0 }, { coverage_revision: -1 }, { rotation_revision: -1 }, { lifecycle_revision: -1 }, { notification_revision: -1 }, { lock_version: -1 }, { slack_enabled: true }, { slack_webhook_url: "ciphertext" }, { slack_webhook_configured_at: @now }].each { |values|
      rejects("schedules", values)
    }
    committed = { coverage_revision: 1, coverage_start_boundary: 1, coverage_starts_at: @now,
                  generated_through_boundary: 3, rotation_effective_boundary: 1 }
    { "scheduled" => committed, "active" => committed.merge(first_activated_at: @now),
      "pausing" => committed.merge(first_activated_at: @now, rotation_effective_boundary: nil, pause_effective_at: @now + 1.week), "paused" => { coverage_revision: 1, first_activated_at: @now } }.each do |state, values|
      assert insert("schedules", values.merge(state: state, name: state))
      rejects("schedules", values.merge(state: state, name: "Invalid", coverage_revision: 0))
    end
    [{ coverage_start_boundary: -1 }, { generated_through_boundary: 0 }, { rotation_effective_boundary: 0 },
     { rotation_effective_boundary: 4 }, { pause_effective_at: @now }, { first_activated_at: @now + 1 }].each { |values|
      rejects("schedules", committed.merge(state: "scheduled").merge(values))
    }
    assert insert("schedules", name: "Reused draft", coverage_revision: 1)
    assert insert("schedules", name: "Configured", slack_webhook_url: "ciphertext", slack_webhook_configured_at: @now,
                               slack_enabled: true)
  end

  test "membership position uniqueness and restrictive foreign keys are enforced" do
    rejects("schedule_memberships", position: -1)
    rejects("schedule_memberships", person_id: 9_999_999)
    rejects("schedule_memberships", schedule_id: 9_999_999)
    insert("schedule_memberships")
    rejects("schedule_memberships", position: 1)
    rejects("schedule_memberships", person_id: @other.id)
    assert_rejected { connection.execute("DELETE FROM munawaba_people WHERE id = #{@person.id}") }
    assert_rejected { connection.execute("DELETE FROM munawaba_schedules WHERE id = #{@schedule.id}") }
    assert_equal 1, connection.delete("DELETE FROM munawaba_schedule_memberships WHERE schedule_id = #{@schedule.id}")
  end

  test "live range exclusion uses half open intervals and canceled slots permit new revisions" do
    [{ coverage_revision: 0 }, { boundary_index: -1 }, { rotation_revision: -1 }, { assignment_version: 0 },
     { timing_version: 0 }, { lock_version: -1 }, { ends_at: @now }, { ends_at: @now + 1.week }, { canceled_at: @now }, { cancellation_reason: "pause" }, { canceled_at: @now, cancellation_reason: "other" }, { starts_at: @now + 1.day }, { base_person_id: 9_999_999 }, { effective_person_id: 9_999_999 }, { schedule_id: 9_999_999 }].each { |values|
      rejects("shifts", values)
    }
    insert("shifts") # Exactly adjacent is valid.
    rejects("shifts", coverage_revision: 2) # Live logical slot remains unique.
    connection.execute("UPDATE munawaba_shifts SET canceled_at = #{connection.quote(@now)}, cancellation_reason = 'pause' WHERE schedule_id = #{@schedule.id} AND boundary_index = 1")
    assert insert("shifts", coverage_revision: 2)
    rejects("shifts", coverage_revision: 1, canceled_at: @now, cancellation_reason: "pause")
    assert connection.select_value("SELECT condeferrable FROM pg_constraint WHERE conname = 'mn_shifts_no_live_overlap'")
  end

  test "override live uniqueness reason bounds and terminal row shape are enforced" do
    [{ replacement_person_id: @person.id }, { replacement_person_id: 9_999_999 }, { previous_person_id: 9_999_999 },
     { shift_id: 9_999_999 }, { reason: "" }, { reason: " whitespace " }, { reason: "x" * 1001 }, { ended_at: @now }, { end_reason: "revoked" }, { ended_at: @now - 1, end_reason: "revoked" }, { ended_at: @now, end_reason: "unknown" }].each { |values|
      rejects("shift_overrides", values)
    }
    insert("shift_overrides")
    rejects("shift_overrides")
    assert insert("shift_overrides", ended_at: @now, end_reason: "superseded")
  end

  test "delivery enum key status lease expiration kind and context contracts are enforced" do
    [{ kind: "email" }, { status: "ready" }, { event_key: "" }, { event_key: " bad" }, { attempt_count: -1 },
     { notification_revision: -1 }, { expires_at: @now }, { next_attempt_at: nil }, { claim_token: SecureRandom.uuid }, { lease_expires_at: @now + 1 }, { enqueued_at: @now }, { processing_at: @now }, { delivered_at: @now }, { last_error_code: "raw exception text" }, { last_http_status: 999 }, { status: "failed", next_attempt_at: nil }, { kind: "shift_start" }, { kind: "next_assignment_change" }, { context: [] }, { context: { payload: "x" * 16385 } }, { schedule_id: 9_999_999 }, { retry_of_delivery_id: 9_999_999 }].each { |values|
      rejects("notification_deliveries", values)
    }
    insert("notification_deliveries")
    rejects("notification_deliveries")
    %w[enqueued processing delivered failed canceled stale].each do |status|
      fields = { status: status, next_attempt_at: nil, event_key: "status:#{status}" }
      fields.merge!(claim_token: SecureRandom.uuid, lease_expires_at: @now + 120, enqueued_at: @now) if %w[enqueued
                                                                                                           processing].include?(status)
      fields[:processing_at] = @now if status == "processing"
      fields[:delivered_at] = @now if status == "delivered"
      fields[:last_error_code] = "delivery_outcome_unknown" if status == "failed"
      assert insert("notification_deliveries", fields)
      rejects("notification_deliveries", fields.merge(event_key: "invalid", next_attempt_at: @now))
    end
    assert insert("notification_deliveries", event_key: "shift", kind: "shift_start", shift_id: @shift.id,
                                             coverage_revision: 1, assignment_version: 1, timing_version: 1)
    assert insert("notification_deliveries", event_key: "next", kind: "next_assignment_change", coverage_revision: 1,
                                             rotation_revision: 1, timing_version: 1)
    rejects("notification_deliveries", event_key: "test:versions", coverage_revision: 1)
  end

  test "activity keeps payload bounds and references without imposing a catalog or provenance envelope" do
    [{ event_type: "x" * 101 }, { metadata: [] }, { metadata: { payload: "x" * 131073 } },
     { actor_type: "x" * 101 }, { actor_id: "x" * 256 }, { actor_name: "x" * 256 }, { person_id: 9_999_999 }, { schedule_id: 9_999_999 }, { shift_id: 9_999_999 }].each { |values|
      rejects("audit_events", values)
    }
    id = insert("audit_events")
    assert_equal 1, connection.update("UPDATE munawaba_audit_events SET actor_name = 'Changed' WHERE id = #{id}")
    assert_equal 1, connection.delete("DELETE FROM munawaba_audit_events WHERE id = #{id}")
    assert insert("audit_events", event_type: "host.note", actor_type: nil, actor_id: nil, metadata: {})
    assert insert("audit_events", actor_type: nil, actor_id: "host-actor", metadata: { details: "Optional actor snapshot" })
  end

  private

  def connection = ActiveRecord::Base.connection

  def insert(table, values = {})
    row = @valid.fetch(table).merge(values)
    quoted = row.values.map { |value|
      connection.quote(value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value)
    }
    connection.exec_query("INSERT INTO munawaba_#{table} (#{row.keys.map { |key|
      connection.quote_column_name(key)
    }.join(", ")}) VALUES (#{quoted.join(", ")}) RETURNING id").rows.first.first
  end

  def rejects(table, values = {})
    assert_rejected("#{table}: #{values.keys.join(", ")}") { insert(table, values) }
  end

  def assert_rejected(message = nil)
    assert_raises(ActiveRecord::StatementInvalid, message.to_s) do
      ActiveRecord::Base.transaction(requires_new: true) { yield }
    end
  end
end
