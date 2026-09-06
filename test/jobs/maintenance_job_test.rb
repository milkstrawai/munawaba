require "test_helper"

class MaintenanceJobTest < ActiveSupport::TestCase
  def schedule(name, state = "draft")
    now = Time.current
    attributes = { name: name, state: state, cadence: "one_week", time_zone: "UTC",
                   anchor_local_date: Date.today, anchor_local_seconds: 0 }
    unless state == "draft"
      attributes.merge!(coverage_revision: 1, coverage_start_boundary: 0, coverage_starts_at: now,
                        generated_through_boundary: 3, rotation_effective_boundary: state == "pausing" ? nil : 0,
                        first_activated_at: state == "scheduled" ? nil : now,
                        pause_effective_at: state == "pausing" ? now + 1.hour : nil)
    end
    Munawaba::Schedule.create!(attributes)
  end

  test "minute maintenance advances schedules before reclaiming and dispatching delivery claims" do
    first, second = schedule("First", "scheduled"), schedule("Second", "pausing")
    order = sequence("minute maintenance")
    Munawaba::Shifts::NormalizeFutureTiming.expects(:call).with(schedule: first).in_sequence(order)
    Munawaba::Shifts::NormalizeFutureTiming.expects(:call).with(schedule: second).in_sequence(order)
    Munawaba::Notifications::ReclaimExpiredLeases.expects(:call).in_sequence(order)
    Munawaba::Notifications::Dispatcher.expects(:call).in_sequence(order)

    Munawaba::MaintenanceJob.perform_now
  end

  test "one schedule and reclaim failure do not prevent other schedules or dispatch" do
    first, second = schedule("First", "scheduled"), schedule("Second", "scheduled")
    failure = RuntimeError.new("schedule failure")
    Munawaba::Shifts::NormalizeFutureTiming.expects(:call).with(schedule: first).raises(failure)
    Munawaba::Shifts::NormalizeFutureTiming.expects(:call).with(schedule: second)
    Munawaba::Notifications::ReclaimExpiredLeases.expects(:call).raises(RuntimeError, "reclaim failure")
    Munawaba::Notifications::Dispatcher.expects(:call)

    assert_same failure, assert_raises(RuntimeError) { Munawaba::MaintenanceJob.perform_now }
  end

  test "daily maintenance normalizes and extends live schedules while completing pending pauses" do
    active = schedule("Active", "active")
    scheduled = schedule("Scheduled", "scheduled")
    pausing = schedule("Pausing", "pausing")
    schedule("Draft")
    Munawaba::Shifts::Project.expects(:call).with(schedule: active, observed_revision: nil)
    Munawaba::Shifts::Project.expects(:call).with(schedule: scheduled, observed_revision: nil)
    Munawaba::Shifts::NormalizeFutureTiming.expects(:call).with(schedule: pausing)

    Munawaba::MaintainProjectionJob.perform_now
  end

  test "daily maintenance finishes other schedules before reporting a projection failure" do
    first, second = schedule("First", "active"), schedule("Second", "active")
    failure = RuntimeError.new("projection failure")
    Munawaba::Shifts::Project.expects(:call).with(schedule: first, observed_revision: nil).raises(failure)
    Munawaba::Shifts::Project.expects(:call).with(schedule: second, observed_revision: nil)

    assert_same failure, assert_raises(RuntimeError) { Munawaba::MaintainProjectionJob.perform_now }
  end

  test "on-demand projection keeps the schedule and revision guard" do
    active, pausing = schedule("Active", "active"), schedule("Pausing", "pausing")
    Munawaba::Shifts::Project.expects(:call).with(schedule: active, observed_revision: 12)
    Munawaba::Shifts::NormalizeFutureTiming.expects(:call).never

    Munawaba::MaintainProjectionJob.perform_now(active.id, 12)
    Munawaba::MaintainProjectionJob.perform_now(pausing.id, 12)
  end

  test "on-demand timing repair targets one active schedule without dispatching unrelated deliveries" do
    active = schedule("Active", "active")
    schedule("Other", "scheduled")
    Munawaba::Shifts::NormalizeFutureTiming.expects(:call).with(schedule: active)
    Munawaba::Shifts::Project.expects(:call).never
    Munawaba::Notifications::ReclaimExpiredLeases.expects(:call).never
    Munawaba::Notifications::Dispatcher.expects(:call).never

    Munawaba::MaintenanceJob.perform_now(active.id)
  end
end
