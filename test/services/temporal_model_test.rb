require "test_helper"

class TemporalModelTest < ActiveSupport::TestCase
  def rule(date:, zone: "UTC", cadence: "one_week", seconds: 9 * 3600)
    Munawaba::Schedule.new(name: "Rule", cadence: cadence, time_zone: zone, anchor_local_date: date,
                           anchor_local_seconds: seconds)
  end

  test "monthly boundaries restore the original day after February" do
    calc = Munawaba::Timing::BoundaryCalculator.new(rule(date: Date.new(2024, 1, 31), cadence: "calendar_month"))
    assert_equal([Date.new(2024, 1, 31), Date.new(2024, 2, 29), Date.new(2024, 3, 31)], (0..2).map { |index|
      calc.boundary(index).nominal_local_date
    })
    assert_equal 25, calc.slot_at(Time.utc(2026, 3, 15))
  end

  test "DST gap advances only the occurrence by the actual offset delta" do
    calc = Munawaba::Timing::BoundaryCalculator.new(rule(date: Date.new(2026, 3, 8), zone: "America/New_York",
                                                         seconds: (2 * 3600) + (30 * 60)))
    first = calc.boundary(0)
    assert_equal "gap_forward", first.resolution
    assert_equal 3600, first.adjustment_seconds
    assert_equal Time.utc(2026, 3, 8, 7, 30), first.resolved_at
    assert_equal Time.utc(2026, 3, 15, 6, 30), calc.boundary(1).resolved_at
    lord_howe = Munawaba::Timing::BoundaryCalculator.new(rule(date: Date.new(2026, 10, 4), zone: "Australia/Lord_Howe",
                                                              seconds: (2 * 3600) + (15 * 60))).boundary(0)
    assert_equal "gap_forward", lord_howe.resolution
    assert_equal 1800, lord_howe.adjustment_seconds
  end

  test "ambiguous boundary selects earlier UTC and half-open lookup selects newly started slot" do
    calc = Munawaba::Timing::BoundaryCalculator.new(rule(date: Date.new(2026, 11, 1), zone: "America/New_York",
                                                         seconds: 90 * 60))
    assert_equal "ambiguous_earlier", calc.boundary(0).resolution
    assert_equal Time.utc(2026, 11, 1, 5, 30), calc.boundary(0).resolved_at
    assert_equal 1, calc.slot_at(calc.boundary(1).resolved_at)
  end
  test "weekly fortnightly and monthly rules stay monotonic across diverse offsets" do
    %w[Pacific/Chatham Asia/Kathmandu Pacific/Apia Europe/London America/New_York Australia/Lord_Howe].each do |zone|
      %w[one_week two_weeks calendar_month].each do |cadence|
        calc = Munawaba::Timing::BoundaryCalculator.new(rule(date: Date.new(2024, 1, 31), zone: zone, cadence: cadence,
                                                             seconds: (2 * 3600) + (30 * 60)))
        boundaries = (0..36).map { |index| calc.boundary(index) }
        assert boundaries.each_cons(2).all? { |left, right| left.resolved_at < right.resolved_at }, "#{zone} #{cadence}"
        boundaries.drop(1).each { |boundary| assert_equal boundary.index, calc.slot_at(boundary.resolved_at) }
      end
    end
  end

  test "projection canonical bytes ignore labels and values remain deeply immutable" do
    schedule = rule(date: Date.new(2026, 1, 31), cadence: "calendar_month")
    schedule.id = 17
    now = Time.utc(2026, 2, 2, 12, 34, Rational(5_123456, 1_000000))
    first = Munawaba::Shifts::ProjectionPlan.new(schedule: schedule, operation_kind: "immediate_activation", now: now,
                                                 person_ids: [22, 31], first_boundary: 0, target_boundary: 2, conflict_check_at: now)
    schedule.name = "A completely different display label"
    second = Munawaba::Shifts::ProjectionPlan.new(schedule: schedule, operation_kind: "immediate_activation", now: now,
                                                  person_ids: [22, 31], first_boundary: 0, target_boundary: 2, conflict_check_at: now)
    assert_equal first.canonical, second.canonical
    assert_equal first.digest, second.digest
    assert_equal 4, first.boundaries.length
    assert_equal 3, first.slots.length
    assert_equal Munawaba::Canonical.micros(now), first.canonical[9]
    assert_raises(FrozenError) { first.slots.first[:base_person_id] = 99 }
    assert_raises(FrozenError) { first.canonical.last << [] }
    persistence = first.persistence_slots(now: now + 1)
    assert_equal now + 1, persistence.first[:starts_at]
    assert_equal first.slots.drop(1), persistence.drop(1)
    assert_equal now, first.slots.first[:starts_at]
  end
end
