require "test_helper"

class DomainTimingTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 9, 5, 12)
    travel_to @now
    @people = 2.times.map { |index| Munawaba::Person.create!(name: "Timing #{index}", email: "timing#{index}@example.org") }
    @schedule = Munawaba::Schedule.create!(name: "Timing", cadence: "one_week", time_zone: "UTC",
                                           anchor_local_date: Date.new(2026, 9, 10), anchor_local_seconds: 9 * 3600)
    @people.each_with_index { |person, index| Munawaba::ScheduleMembership.create!(schedule: @schedule, person: person, position: index) }
    execute(:activate)
  end

  teardown do
    travel_back
  end

  def execute(operation, subject = @schedule, attributes = {})
    preview = Munawaba::Commands.preview(operation: operation, subject: subject, attributes: attributes, actor: actor)
    assert preview.success?, preview.errors.inspect
    result = Munawaba::Commands.call(operation: operation, subject: subject, attributes: attributes, actor: actor,
                                     token: preview.preview.token, acknowledge_conflicts: true)
    assert result.success?, result.errors.inspect
    result
  end

  def shift_rules(seconds)
    period = Struct.new(:utc_total_offset).new(seconds)
    zone = Object.new
    zone.define_singleton_method(:periods_for_local) { |_local| [period] }
    Munawaba::Timing::BoundaryCalculator.stubs(:timezone).returns(zone)
  end

  test "lifecycle resolves a delayed start before deciding the persisted timestamp is due" do
    original = @schedule.reload.coverage_starts_at
    travel_to original + 30.minutes
    shift_rules(-3600)
    Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule)
    assert_equal "scheduled", @schedule.reload.state
    assert_equal original + 1.hour, @schedule.coverage_starts_at
    assert_nil @schedule.first_activated_at
    assert_equal 2, @schedule.shifts.order(:boundary_index).first.timing_version
  end

  test "moving start into now blocks deactivation until timing maintenance clips and audits once" do
    shift_rules(6.days.to_i)
    preview = Munawaba::Commands.preview(operation: :deactivate, subject: @people[1], actor: actor)
    assert_equal 200, preview.status
    assert_nil preview.preview.token
    assert preview.preview.details[:blockers].any?
    first = @schedule.shifts.order(:boundary_index).first
    original = first.starts_at
    assert_equal original, first.reload.starts_at
    assert_no_difference "Munawaba::AuditEvent.count" do
      result = Munawaba::Commands.call(operation: :deactivate, subject: @people[1], actor: actor, token: "bad")
      assert_equal 409, result.status
    end
    Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule)
    assert_equal "active", @schedule.reload.state
    assert_equal Time.current, @schedule.first_activated_at
    assert_equal Time.current, first.reload.starts_at
    events = Munawaba::AuditEvent.where(event_type: %w[timing.future_projection_recomputed schedule.activated])
    assert_equal 2, events.count
    assert_equal 1, events.pluck(:operation_id).uniq.length
    execute(:deactivate, @people[1])
    assert_not @people[1].reload.active?
  end

  test "current timing remains frozen and first future shift meets its persisted end" do
    travel_to @schedule.reload.coverage_starts_at + 1.hour
    Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule)
    current = @schedule.current_shift
    original = current.attributes
    shift_rules(1800)
    Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule)
    assert_equal original, current.reload.attributes
    future = @schedule.next_shift
    assert_equal current.ends_at, future.starts_at
    assert_equal Munawaba::Timing::BoundaryCalculator.new(@schedule).boundary(future.boundary_index + 1).resolved_at,
                 future.ends_at
    execute(:rotation, @schedule, { person_ids: @people.reverse.map(&:id) })
    assert_equal current.ends_at, @schedule.next_shift.starts_at
    assert_equal original, current.reload.attributes
  end

  test "nonpositive timing projection rolls back every retained change" do
    shift_rules(30.days.to_i)
    before = @schedule.shifts.order(:id).pluck(:starts_at, :ends_at, :timing_version)
    assert_raises(ArgumentError) { Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule) }
    assert_equal before, @schedule.shifts.order(:id).pluck(:starts_at, :ends_at, :timing_version)
    assert_equal "scheduled", @schedule.reload.state
  end
  test "normalization preflight reports only actual lifecycle or interval changes" do
    prepared = Munawaba::Shifts::NormalizeFutureTiming.prepare(schedule: @schedule.reload, now: Time.current)
    assert_not prepared.changed?
    shift_rules(1800)
    prepared = Munawaba::Shifts::NormalizeFutureTiming.prepare(schedule: @schedule, now: Time.current)
    assert prepared.changed?
    assert_equal "scheduled", @schedule.reload.state
  end

  test "on-demand repair changes future timing without extending an active schedule" do
    travel_to @schedule.reload.coverage_starts_at + 1.hour
    Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule)
    travel 2.weeks
    cursor = @schedule.generated_through_boundary
    shift_rules(1800)

    assert_no_difference "@schedule.shifts.count" do
      Munawaba::MaintenanceJob.perform_now(@schedule.id)
    end
    assert_equal cursor, @schedule.reload.generated_through_boundary
    assert_equal "active", @schedule.state
    assert_equal 2, @schedule.next_shift.timing_version
  end

  test "timing repair and projection extension roll back together after a late audit failure" do
    integration = Munawaba::Integrations.call(operation: :update, schedule: @schedule,
                                              attributes: { slack_webhook_url: "https://hooks.slack.com/services/T000/B000/secret", slack_enabled: true }, actor: actor)
    assert integration.success?, integration.errors.inspect
    travel_to @schedule.reload.coverage_starts_at + 1.hour
    Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule)
    travel 2.weeks
    future = @schedule.next_shift
    shift_rules(1800)

    snapshot = -> {
      { schedule: @schedule.reload.attributes,
        shifts: @schedule.shifts.order(:id).map(&:attributes),
        deliveries: @schedule.notification_deliveries.order(:id).map(&:attributes),
        activity: @schedule.audit_events.order(:id).map(&:attributes) }
    }
    before = snapshot.call
    reject_projection = ->(event) {
      event.errors.add(:base, "Projection audit failed") if event.event_type == "timing.projection_extended"
    }
    Munawaba::AuditEvent.validate reject_projection
    begin
      ActiveRecord::Base.transaction do
        error = assert_raises(ActiveRecord::RecordInvalid) { Munawaba::Shifts::Project.call(schedule: @schedule) }
        assert_equal "timing.projection_extended", error.record.event_type
        assert_equal before, snapshot.call
      end
    ensure
      Munawaba::AuditEvent.skip_callback(:validate, :before, reject_projection)
    end

    rows = Munawaba::Shifts::Project.call(schedule: @schedule)
    assert rows.any?
    assert_equal 2, future.reload.timing_version
    assert_operator @schedule.reload.generated_through_boundary, :>, before[:schedule].fetch("generated_through_boundary")
    events = @schedule.audit_events.where(event_type: %w[timing.future_projection_recomputed timing.projection_extended]).order(:id)
    assert_equal %w[timing.future_projection_recomputed timing.projection_extended], events.pluck(:event_type)
    assert_equal 1, events.pluck(:operation_id).uniq.length
    assert_equal [[nil, nil, nil]], events.pluck(:actor_type, :actor_id, :actor_name).uniq
  end
end
