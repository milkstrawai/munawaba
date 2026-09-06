require "test_helper"

class RetainedModelsTest < ActiveSupport::TestCase
  setup do
    @person = Munawaba::Person.create!(name: " Ada ", email: " ADA@example.org ", slack_member_id: " UABC ")
    @other = Munawaba::Person.create!(name: "Grace", email: "grace@example.org")
    @schedule = Munawaba::Schedule.create!(name: " Primary ", cadence: "calendar_month", time_zone: "UTC",
                                           anchor_local_date: Date.new(2026, 9, 1), anchor_local_seconds: 0)
    @shift = Munawaba::Shift.create!(schedule: @schedule, base_person: @person, effective_person: @person,
                                     coverage_revision: 1, boundary_index: 0, starts_at: Time.utc(2026, 9, 1), ends_at: Time.utc(2026, 10, 1), generated_at: Time.current)
  end

  test "people normalize names email and optional Slack identity and validate uniqueness" do
    assert_equal ["Ada", "ada@example.org", "UABC"], @person.values_at(:name, :email, :slack_member_id)
    duplicate = Munawaba::Person.new(name: "Another", email: "ADA@example.org", slack_member_id: "UABC")
    assert_not duplicate.valid?
    assert duplicate.errors.added?(:email, :taken, value: "ada@example.org")
    assert duplicate.errors.added?(:slack_member_id, :taken, value: "UABC")
    @person.update!(slack_member_id: " ")
    assert_nil @person.slack_member_id
    assert_not @person.update(slack_member_id: "<@UABC>")
  end

  test "inactive people cannot enter memberships and reactivation does not restore them" do
    membership = Munawaba::ScheduleMembership.create!(schedule: @schedule, person: @person, position: 0)
    membership.destroy!
    @person.update!(active: false, deactivated_at: Time.current)
    assert_not Munawaba::ScheduleMembership.new(schedule: @schedule, person: @person, position: 0).valid?
    @person.reload.update!(active: true, deactivated_at: nil)
    assert_empty @person.schedule_memberships.reload
  end

  test "foreign keys prevent deletion of referenced records" do
    [@person, @schedule].each do |record|
      error = assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) { record.destroy! }
      end
      assert_includes [PG::ForeignKeyViolation, PG::RestrictViolation], error.cause.class
    end
    membership = Munawaba::ScheduleMembership.create!(schedule: @schedule, person: @person, position: 0)
    assert membership.destroy!
    assert @shift.destroy!
    assert @schedule.destroy!
    assert @person.delete
  end

  test "activity can be created, updated, and deleted without an actor" do
    event = Munawaba::AuditEvent.create!(operation_id: SecureRandom.uuid, event_type: "host.note",
                                         metadata: { message: "Added context" }, occurred_at: Time.current)
    assert_nil event.actor_id
    assert event.update!(metadata: { message: "Corrected context" })
    assert_equal "Corrected context", event.reload.metadata.fetch("message")
    assert_not event.update(event_type: "")
    assert_not event.update(metadata: [])
    assert_not event.update(metadata: { message: "x" * 131073 })
    assert event.destroy!
  end

  test "schedule enforces canonical timezone minute precision and immutable committed timing" do
    assert_equal "Primary", @schedule.name
    assert_not @schedule.update(anchor_local_date: Date.new(10000, 1, 1))
    @schedule.reload
    assert_not @schedule.update(time_zone: "Pacific time")
    @schedule.reload
    assert_not @schedule.update(anchor_local_seconds: 1)
    @schedule.reload.update!(state: "active", first_activated_at: Time.utc(2026, 9, 1), coverage_revision: 1,
                             coverage_start_boundary: 0, coverage_starts_at: Time.utc(2026, 9, 1), generated_through_boundary: 0, rotation_effective_boundary: 0)
    assert_not @schedule.update(cadence: "one_week")
    assert_match(/Timing can only change on a draft that has never started/, @schedule.errors.full_messages.join)
    assert @schedule.reload.update(name: "Renamed")
  end

  test "webhooks are encrypted, filtered, and require a matching configuration timestamp" do
    url = "https://hooks.slack.com/services/TEAM/CHANNEL/SECRET"
    assert_not @schedule.update(slack_webhook_url: url)
    @schedule.reload.update!(slack_webhook_url: url, slack_webhook_configured_at: Time.current, slack_enabled: true)
    raw = ActiveRecord::Base.connection.select_value("SELECT slack_webhook_url FROM munawaba_schedules WHERE id=#{@schedule.id}")
    assert_not_includes raw, "SECRET"
    assert_not_includes @schedule.inspect, "SECRET"
    assert_equal url, @schedule.reload.slack_webhook_url
    assert_not @schedule.update(slack_webhook_url: "https://evil.example/services/a/b/c")
  end

  test "canceled shifts and ended overrides are terminal through model updates" do
    override = Munawaba::ShiftOverride.create!(shift: @shift, previous_person: @person, replacement_person: @other,
                                               reason: " Cover ")
    assert_equal "Cover", override.reason
    assert_not override.update(reason: "Altered history")
    override.reload.update!(ended_at: Time.current, end_reason: "revoked")
    assert_not override.update(ended_at: nil, end_reason: nil)
    @shift.update!(canceled_at: Time.current, cancellation_reason: "pause")
    assert_not @shift.update(canceled_at: nil, cancellation_reason: nil)
  end

  test "half open current future overlap scopes exclude touching endpoints" do
    assert_equal @shift, Munawaba::Shift.live.current(Time.utc(2026, 9, 1)).sole
    assert_empty Munawaba::Shift.live.current(Time.utc(2026, 10, 1))
    assert_empty Munawaba::Shift.live.overlapping(Time.utc(2026, 10, 1), Time.utc(2026, 10, 2))
    assert_equal @shift, Munawaba::Shift.live.overlapping(Time.utc(2026, 9, 30), Time.utc(2026, 10, 2)).sole
  end

  test "typed delivery context and terminal history are guarded" do
    delivery = Munawaba::NotificationDelivery.new(schedule: @schedule, kind: "test", status: "pending",
                                                  event_key: "model:test", notification_revision: 0, context: { "schema_version" => 1 }, due_at: Time.current, next_attempt_at: Time.current, expires_at: 10.minutes.from_now)
    assert delivery.valid?
    delivery.context = { "schema_version" => 1, "webhook" => "secret" }
    assert_not delivery.valid?
    delivery.context = { "schema_version" => 1 }
    delivery.save!
    delivery.update!(status: "failed", next_attempt_at: nil, last_error_code: "delivery_outcome_unknown")
    assert_not delivery.update(status: "pending", next_attempt_at: Time.current)
  end
end
