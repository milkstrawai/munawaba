require "test_helper"

class DomainSafetyTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 9, 5, 12)
    travel_to @now
    @people = 3.times.map { |index| Munawaba::Person.create!(name: "Person #{index}", email: "person#{index}@example.org") }
    @schedule = build_schedule("Alpha")
  end

  teardown do
    travel_back
  end

  def build_schedule(name, future: false)
    schedule = Munawaba::Schedule.create!(name: name, cadence: "one_week", time_zone: "UTC",
                                          anchor_local_date: future ? Date.new(2026, 9, 10) : Date.new(2026, 9, 1), anchor_local_seconds: 9 * 3600)
    @people.each_with_index { |person, index| Munawaba::ScheduleMembership.create!(schedule: schedule, person: person, position: index) }
    schedule
  end

  def proposal(operation, subject = @schedule, attributes = {})
    result = Munawaba::Commands.preview(operation: operation, subject: subject, attributes: attributes, actor: actor)
    assert result.success?, result.errors.inspect
    result.preview
  end

  def submit(operation, preview, subject = @schedule, attributes = {})
    Munawaba::Commands.call(operation: operation, subject: subject, attributes: attributes, actor: actor,
                            token: preview.token, acknowledge_conflicts: true)
  end

  def activate(schedule = @schedule)
    result = submit(:activate, proposal(:activate, schedule), schedule)
    assert result.success?, result.errors.inspect
    schedule.reload
  end

  def shifted_provider(seconds)
    period = Struct.new(:utc_total_offset).new(seconds)
    zone = Object.new
    zone.define_singleton_method(:periods_for_local) { |_local| [period] }
    ->(_name) { zone }
  end

  test "changed provider invalidates empty-conflict projection without retained writes" do
    preview = proposal(:activate)
    assert_empty preview.conflicts
    Munawaba::Timing::BoundaryCalculator.stubs(:timezone).returns(shifted_provider(1800).call("UTC"))
    assert_no_difference ["Munawaba::Shift.count", "Munawaba::AuditEvent.count",
                          "Munawaba::NotificationDelivery.count"] do
      result = submit(:activate, preview)
      assert_equal 409, result.status
    end
    assert_equal "draft", @schedule.reload.state
  end

  test "missing forged and different-purpose tokens never mutate" do
    preview = proposal(:activate)
    [nil, "garbage", preview.token.reverse].each do |token|
      result = Munawaba::Commands.call(operation: :activate, subject: @schedule, actor: actor, token: token)
      assert_equal 409, result.status
    end
    result = Munawaba::Commands.call(operation: :rotation, subject: @schedule, actor: actor, token: preview.token)
    assert_equal 409, result.status
    assert_equal "draft", @schedule.reload.state
    assert_empty @schedule.shifts
  end

  test "activation across containing-slot boundary becomes stale" do
    preview = proposal(:activate)
    travel_to preview.projection.first[:ends_at]
    assert_equal 409, submit(:activate, preview).status
    assert_empty @schedule.shifts
  end

  test "ordinary horizon passage retains exact signed target and maintenance extends independently" do
    # The extra month of projection lets the selectable horizon advance while
    # immediate activation still uses the same handoff interval.
    travel_to Time.utc(2026, 9, 4, 12)
    preview = proposal(:activate)
    travel 1.day
    result = submit(:activate, preview)
    assert result.success?, result.errors.inspect
    assert_equal preview.details[:generated_through_boundary], @schedule.reload.generated_through_boundary
    first_count = @schedule.shifts.count
    Munawaba::Shifts::Project.call(schedule: @schedule)
    assert_operator @schedule.shifts.count, :>, first_count
    second_count = @schedule.shifts.count
    Munawaba::Shifts::Project.call(schedule: @schedule)
    assert_equal second_count, @schedule.shifts.count
  end

  test "changed conflict even outside the six-row display invalidates acknowledgment" do
    activate
    attributes = { person_ids: @people.reverse.map(&:id) }
    preview = proposal(:rotation, @schedule, attributes)
    affected = preview.projection.fetch(10)
    other = build_schedule("Beta")
    Munawaba::Shift.create!(schedule: other, coverage_revision: 1, boundary_index: affected[:boundary_index],
                            starts_at: affected[:starts_at], ends_at: affected[:ends_at], generated_at: @now,
                            base_person_id: affected[:effective_person_id], effective_person_id: affected[:effective_person_id], rotation_revision: 0, assignment_version: 1, timing_version: 1)
    before = @schedule.ordered_person_ids
    assert_equal 409, submit(:rotation, preview, @schedule, attributes).status
    assert_equal before, @schedule.ordered_person_ids
  end

  test "draft timing changes invalidate a roster preview even without projected shifts" do
    attributes = { person_ids: @people.reverse.map(&:id) }
    preview = proposal(:rotation, @schedule, attributes)
    assert_empty preview.projection
    before = @schedule.ordered_person_ids
    @schedule.update!(time_zone: "Australia/Sydney")

    assert_no_difference ["Munawaba::Shift.count", "Munawaba::AuditEvent.count"] do
      assert_equal 409, submit(:rotation, preview, @schedule, attributes).status
    end
    assert_equal before, @schedule.ordered_person_ids
  end

  test "deactivation blocks future override including an override-only schedule and then allows current to finish" do
    activate
    outsider = Munawaba::Person.create!(name: "Outside", email: "outside@example.org")
    future = @schedule.next_shift
    attributes = { person_id: outsider.id }
    assert submit(:override, proposal(:override, future, attributes), future, attributes).success?
    preview = proposal(:deactivate, outsider)
    assert_equal([@schedule.id], preview.details[:schedule_plans].map { |plan| plan[:schedule_id] })
    assert preview.details[:blockers].any?
    assert_equal 422, submit(:deactivate, preview, outsider).status
    assert outsider.reload.active?
    travel_to future.starts_at
    result = submit(:deactivate, proposal(:deactivate, outsider), outsider)
    assert result.success?, result.errors.inspect
    assert_not outsider.reload.active?
    assert_equal outsider.id, future.reload.effective_person_id
  end

  test "deactivation normalizes all proposed schedules before a single proposed/proposed conflict calculation" do
    activate
    other = build_schedule("Beta")
    activate(other)
    preview = proposal(:deactivate, @people[1])
    assert preview.conflicts.any?
    assert_equal preview.conflicts.uniq, preview.conflicts
    assert_equal 2, preview.details[:schedule_plans].length
    result = submit(:deactivate, preview, @people[1])
    assert result.success?, result.errors.inspect
    assert_equal @schedule.ordered_person_ids, other.ordered_person_ids
    assert_equal 1,
                 Munawaba::AuditEvent.where(event_type: %w[person.deactivated
                                                           rotation.changed_by_deactivation]).pluck(:operation_id).uniq.length
  end

  test "provider-only future normalization is read-only until confirmation and stale failures roll it back" do
    future = build_schedule("Future", future: true)
    activate(future)
    preview = proposal(:rotation, future, { person_ids: @people.reverse.map(&:id) })
    old = future.shifts.order(:id).pluck(:starts_at, :ends_at, :timing_version)
    Munawaba::Timing::BoundaryCalculator.stubs(:timezone).returns(shifted_provider(1800).call("UTC"))
    refreshed = proposal(:rotation, future, { person_ids: @people.reverse.map(&:id) })
    assert_equal old, future.shifts.order(:id).pluck(:starts_at, :ends_at, :timing_version)
    assert_equal 409, submit(:rotation, preview, future, { person_ids: @people.reverse.map(&:id) }).status
    assert_equal old, future.shifts.order(:id).pluck(:starts_at, :ends_at, :timing_version)
    result = submit(:rotation, refreshed, future, { person_ids: @people.reverse.map(&:id) })
    assert result.success?, result.errors.inspect
    assert_equal old.first[0] - 1800, future.shifts.order(:id).first.starts_at
    assert_equal 2, future.shifts.order(:id).first.timing_version
  end

  test "future scheduled cancellation can discard provider movement but cannot cancel a due run" do
    future = build_schedule("Future", future: true)
    activate(future)
    preview = proposal(:cancel_scheduled, future)
    Munawaba::Timing::BoundaryCalculator.stubs(:timezone).returns(shifted_provider(1800).call("UTC"))
    result = submit(:cancel_scheduled, preview, future)
    assert result.success?, result.errors.inspect
    assert_equal "draft", future.reload.state
    assert_equal [1], future.shifts.pluck(:timing_version).uniq
    activate(future)
    preview = proposal(:cancel_scheduled, future)
    travel_to future.coverage_starts_at
    stale = submit(:cancel_scheduled, preview, future)
    assert_equal 409, stale.status
    assert_equal "pause", stale.preview.details[:operation]
    assert_equal "scheduled", future.reload.state
    assert submit(:pause, stale.preview, future).success?
    assert_equal "pausing", future.reload.state
  end
  test "a future revoke crossing its start becomes an explicitly separate restore confirmation" do
    activate
    future = @schedule.next_shift
    attributes = { person_id: @people[2].id }
    assert submit(:override, proposal(:override, future, attributes), future, attributes).success?
    previous = proposal(:revoke, future)
    travel_to future.starts_at
    result = submit(:revoke, previous, future)
    assert_equal 409, result.status
    assert_equal "restore_to_base", result.preview.details[:operation]
    assert future.reload.active_override
    assert submit(:restore_to_base, result.preview, future).success?
    assert_nil future.reload.active_override
  end

  test "computed Next follows persisted handoffs after several cycles and never resolves timing on reads" do
    activate
    attributes = { person_ids: @people.reverse.map(&:id) }
    result = submit(:rotation, proposal(:rotation, @schedule, attributes), @schedule, attributes)
    assert result.success?, result.errors.inspect
    @schedule.reload
    expected_order = @schedule.ordered_person_ids
    calculator = Munawaba::Timing::BoundaryCalculator.new(@schedule)
    travel_to calculator.boundary(8).resolved_at
    expected_boundary = 9
    expected_person = expected_order[(expected_boundary - @schedule.rotation_effective_boundary) % expected_order.length]
    assert_equal expected_boundary, @schedule.next_shift.boundary_index
    controller = Munawaba::ApplicationController.new
    Munawaba::Timing::BoundaryCalculator.expects(:timezone).never
    before = @schedule.shifts.order(:id).pluck(:id, :lock_version, :starts_at, :ends_at)
    roster = controller.send(:computed_roster, @schedule, @schedule.schedule_memberships)
    assert_equal expected_person, roster.first.person_id
    assert_equal expected_person, @schedule.next_shift.base_person_id
    assert_equal before, @schedule.shifts.order(:id).pluck(:id, :lock_version, :starts_at, :ends_at)
  end

  test "projection extends the effective rotation formula and ignores obsolete coverage revisions" do
    activate
    attributes = { person_ids: @people.reverse.map(&:id) }
    assert submit(:rotation, proposal(:rotation, @schedule, attributes), @schedule, attributes).success?
    @schedule.reload
    travel 2.weeks
    expected_order = @schedule.ordered_person_ids
    rows = Munawaba::Shifts::Project.call(schedule: @schedule, observed_revision: @schedule.coverage_revision)
    assert rows.any?
    rows.each do |shift|
      assert_equal expected_order[(shift.boundary_index - @schedule.rotation_effective_boundary) % expected_order.length],
                   shift.base_person_id
    end
    assert_no_difference "Munawaba::Shift.count" do
      assert_empty Munawaba::Shifts::Project.call(schedule: @schedule,
                                                  observed_revision: @schedule.coverage_revision - 1)
    end
    assert submit(:pause, proposal(:pause)).success?
    assert_no_difference "Munawaba::Shift.count" do
      assert_empty Munawaba::Shifts::Project.call(schedule: @schedule)
    end
  end

  test "a delayed conflict-bearing activation persists only the acknowledged leading-edge subset" do
    activate
    other = build_schedule("Overlapping")
    proposed = proposal(:activate, other)
    assert proposed.conflicts.any?
    acknowledgment_start = proposed.projection.first[:starts_at]
    travel 20.seconds
    result = submit(:activate, proposed, other)
    assert result.success?, result.errors.inspect
    first = other.shifts.order(:boundary_index).first
    assert_equal Time.current, first.starts_at
    assert_operator first.starts_at, :>, acknowledgment_start
    assert_equal proposed.projection.first[:ends_at], first.ends_at
    event = Munawaba::AuditEvent.find_by!(schedule_id: other.id, event_type: "schedule.activated")
    assert_equal first.starts_at.as_json, event.metadata.fetch("coverage_starts_at")
  end

  test "a still-future signed start refreshes when its cursor no longer covers the calendar promise" do
    @schedule.update!(anchor_local_date: Date.new(2027, 3, 1))
    proposed = proposal(:activate)
    travel_to Time.utc(2026, 11, 5, 12)
    assert_no_difference ["Munawaba::Shift.count", "Munawaba::AuditEvent.count"] do
      result = submit(:activate, proposed)
      assert_equal 409, result.status
      assert_operator result.preview.details[:generated_through_boundary], :>,
                      proposed.details[:generated_through_boundary]
    end
    assert_equal "draft", @schedule.reload.state
  end
end
