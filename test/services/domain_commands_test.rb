require "test_helper"

class DomainCommandsTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 9, 5, 12)
    travel_to @now
    @alice = Munawaba::Person.create!(name: "Alice", email: "alice@example.org")
    @bob = Munawaba::Person.create!(name: "Bob", email: "bob@example.org")
    @carol = Munawaba::Person.create!(name: "Carol", email: "carol@example.org")
    @schedule = Munawaba::Schedule.create!(name: "Primary", cadence: "one_week", time_zone: "UTC",
                                           anchor_local_date: Date.new(2026, 9, 1), anchor_local_seconds: 9 * 3600)
    [@alice, @bob, @carol].each_with_index { |person, position| Munawaba::ScheduleMembership.create!(schedule: @schedule, person: person, position: position) }
  end

  teardown { travel_back }

  def preview(operation, subject = @schedule, attributes = {})
    result = Munawaba::Commands.preview(operation: operation, subject: subject, attributes: attributes, actor: actor)
    assert result.success?, result.errors.inspect
    result.preview
  end

  def confirm(operation, proposed, subject = @schedule, attributes = {}, acknowledge: true)
    Munawaba::Commands.call(operation: operation, subject: subject, attributes: attributes, token: proposed.token,
                            acknowledge_conflicts: acknowledge, actor: actor)
  end

  def activate(item = @schedule)
    result = confirm(:activate, preview(:activate, item), item)
    assert result.success?, result.errors.inspect
    item.reload
  end

  test "create update and optimistic stale edit are audited" do
    record = Munawaba::Person.new
    created = Munawaba::Commands.call(operation: :create_person, subject: record,
                                      attributes: { name: " Dana ", email: "DANA@example.org" }, actor: actor)
    assert created.success?, created.errors.inspect
    assert_equal "dana@example.org", record.email
    updated = Munawaba::Commands.call(operation: :update_person, subject: record,
                                      attributes: { name: "Dana Two", lock_version: record.lock_version }, actor: actor)
    assert updated.success?, updated.errors.inspect
    stale = Munawaba::Commands.call(operation: :update_person, subject: record,
                                    attributes: { name: "Wrong", lock_version: 0 }, actor: actor)
    assert_equal 409, stale.status
    assert_equal "Dana Two", record.reload.name
  end

  test "immediate confirmation clips only the signed first interval and persists exact cursor" do
    proposed = preview(:activate)
    cursor = proposed.details[:generated_through_boundary]
    assert_no_difference "Munawaba::Shift.count" do
      preview(:activate)
    end
    travel 5.minutes
    result = confirm(:activate, proposed)
    assert result.success?, result.errors.inspect
    @schedule.reload
    first = @schedule.shifts.order(:boundary_index).first
    assert_equal Time.current, first.starts_at
    assert_equal proposed.projection.first[:ends_at], first.ends_at
    assert_equal cursor, @schedule.generated_through_boundary
    assert_equal cursor - @schedule.coverage_start_boundary + 1, @schedule.shifts.count
    assert_equal 409, confirm(:activate, proposed).status
  end

  test "future activation materializes before coverage and cancel consumes revision" do
    @schedule.update!(anchor_local_date: Date.new(2026, 9, 10))
    activate
    assert_equal "scheduled", @schedule.state
    assert_nil @schedule.first_activated_at
    cancellation = preview(:cancel_scheduled)
    assert confirm(:cancel_scheduled, cancellation).success?
    assert_equal "draft", @schedule.reload.state
    assert_equal 1, @schedule.coverage_revision
    old_ids = @schedule.shifts.pluck(:id)
    activate
    assert_equal 2, @schedule.coverage_revision
    assert(old_ids.all? { |id| Munawaba::Shift.find(id).canceled? })
  end

  test "rotation keeps current fact and rejects stale second form" do
    activate
    current = @schedule.current_shift
    old = current.attributes
    attributes = { person_ids: [@carol.id, @alice.id, @bob.id] }
    proposed = preview(:rotation, @schedule, attributes)
    result = confirm(:rotation, proposed, @schedule, attributes)
    assert result.success?, result.errors.inspect
    assert_equal old, current.reload.attributes
    assert_equal @carol.id, @schedule.next_shift.base_person_id
    assert_equal 409, confirm(:rotation, proposed, @schedule, attributes).status
  end

  test "override preview authenticates conflicts and replacement preserves history" do
    activate
    other = @schedule.dup
    other.assign_attributes(name: "Secondary", state: "draft", first_activated_at: nil, coverage_revision: 0, coverage_start_boundary: nil,
                            coverage_starts_at: nil, generated_through_boundary: nil, rotation_effective_boundary: nil, lifecycle_revision: 0)
    other.save!
    Munawaba::ScheduleMembership.create!(schedule: other, person: @bob, position: 0)
    activate(other)
    current = @schedule.current_shift
    attributes = { person_id: @bob.id, reason: "Coverage & support" }
    proposed = preview(:override, current, attributes)
    assert proposed.conflicts.any?
    assert_equal 422, confirm(:override, proposed, current, attributes, acknowledge: false).status
    assert confirm(:override, proposed, current, attributes).success?
    attributes = { person_id: @carol.id }
    result = confirm(:override, preview(:override, current, attributes), current, attributes)
    assert result.success?, result.errors.inspect
    assert_equal %w[superseded], current.shift_overrides.where.not(ended_at: nil).pluck(:end_reason)
    assert_equal @carol.id, current.reload.effective_person_id
  end

  test "pause cancels complete horizon and resume never revives canceled slots" do
    activate
    current = @schedule.current_shift
    assert confirm(:pause, preview(:pause)).success?
    assert_equal "pausing", @schedule.reload.state
    assert_equal 1, @schedule.shifts.live.where(coverage_revision: 1).count
    canceled_ids = @schedule.shifts.where.not(canceled_at: nil).pluck(:id)
    travel_to current.ends_at
    Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule)
    assert_equal "paused", @schedule.reload.state
    attributes = { boundary_index: current.boundary_index + 1, person_ids: [@bob.id, @alice.id, @carol.id] }
    result = confirm(:resume, preview(:resume, @schedule, attributes), @schedule, attributes)
    assert result.success?, result.errors.inspect
    assert_equal 2, @schedule.reload.coverage_revision
    assert_equal @bob.id, @schedule.current_shift.effective_person_id
    assert(canceled_ids.all? { |id| Munawaba::Shift.find(id).canceled? })
  end

  test "deactivation chooses deterministic Next and reactivation does not restore membership" do
    activate
    result = confirm(:deactivate, preview(:deactivate, @bob), @bob)
    assert result.success?, result.errors.inspect
    assert_equal [@carol.id, @alice.id], @schedule.ordered_person_ids
    assert_equal @carol.id, @schedule.next_shift.base_person_id
    assert_not @bob.reload.active?
    events = Munawaba::AuditEvent.where(event_type: %w[person.deactivated rotation.changed_by_deactivation])
    assert_equal 1, events.pluck(:operation_id).uniq.length
    reactivated = Munawaba::Commands.call(operation: :reactivate, subject: @bob, actor: actor)
    assert reactivated.success?
    assert_equal [@carol.id, @alice.id], @schedule.ordered_person_ids
  end
  test "late failure rolls back the command even inside a host transaction" do
    person = Munawaba::Person.new
    Munawaba::Audit::Recorder.stubs(:record!).raises(ActiveRecord::RecordInvalid.new(Munawaba::AuditEvent.new))
    ActiveRecord::Base.transaction do
      assert_no_difference ["Munawaba::Person.count", "Munawaba::AuditEvent.count"] do
        result = Munawaba::Commands.call(operation: :create_person, subject: person,
                                         attributes: { name: "Rollback", email: "rollback@example.org" })
        assert_equal 422, result.status
      end
      # The host can continue its transaction after the command returns a failure result.
      assert Munawaba::Person.where(id: @alice.id).exists?
    end
  end

  test "accepted activation persistence and audit reuse the signed timing plan without another provider read" do
    zone = TZInfo::Timezone.get("UTC")
    proposed = preview(:activate)
    compared = false
    Munawaba::Timing::BoundaryCalculator.stubs(:timezone).with { |_name|
      raise "Timing must not be recalculated after projection comparison" if compared

      true
    }.returns(zone)
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      compared = true if payload[:name] == "Munawaba conflicts"
    end
    result = confirm(:activate, proposed)
    assert result.success?, result.errors.inspect
    assert compared
    first = @schedule.shifts.order(:boundary_index).first
    assert_equal proposed.projection.first[:ends_at], first.ends_at
    assert_equal first.starts_at.as_json, Munawaba::AuditEvent.find_by!(event_type: "schedule.activated").metadata.fetch("coverage_starts_at")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
