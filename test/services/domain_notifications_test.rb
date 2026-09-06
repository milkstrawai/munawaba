require "test_helper"

class DomainNotificationsTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 9, 5, 12)
    @people = 3.times.map { |index| Munawaba::Person.create!(name: "Notify #{index}", email: "notify#{index}@example.org") }
    @schedule = Munawaba::Schedule.create!(name: "Notify", cadence: "one_week", time_zone: "UTC", anchor_local_date: Date.new(2026, 9, 10), anchor_local_seconds: 9 * 3600,
                                           slack_webhook_url: "https://hooks.slack.com/services/T000/B000/secret", slack_webhook_configured_at: Time.current, slack_enabled: true)
    @people.each_with_index { |person, index| Munawaba::ScheduleMembership.create!(schedule: @schedule, person: person, position: index) }
  end

  teardown { travel_back }

  def execute(operation, subject = @schedule, attributes = {})
    preview = Munawaba::Commands.preview(operation: operation, subject: subject, attributes: attributes, actor: actor)
    assert preview.success?, preview.errors.inspect
    result = Munawaba::Commands.call(operation: operation, subject: subject, attributes: attributes, actor: actor,
                                     token: preview.preview.token, acknowledge_conflicts: true)
    assert result.success?, result.errors.inspect
    result
  end

  test "future activation plans reminder before run and cancel terminates every unsent intent" do
    execute(:activate)
    @schedule.reload
    first = @schedule.shifts.order(:boundary_index).first
    reminder = first.notification_deliveries.find_by!(kind: "advance_reminder")
    assert_equal first.starts_at - 24.hours, reminder.due_at
    assert_equal first.starts_at, reminder.expires_at
    assert_equal "scheduled", @schedule.state
    execute(:cancel_scheduled)
    assert_equal ["canceled"], @schedule.notification_deliveries.distinct.pluck(:status)
  end

  test "successive override changes retain both audits and stale older assignment notifications" do
    execute(:activate)
    first = @schedule.shifts.order(:boundary_index).first
    execute(:override, first, { person_id: @people[1].id })
    old = first.notification_deliveries.find_by!(kind: "assignment_change", status: "pending")
    assert_equal "override_created", old.context.fetch("transition_type")
    execute(:override, first, { person_id: @people[2].id })
    assert_equal "stale", old.reload.status
    assert_equal 1, first.notification_deliveries.where(kind: "assignment_change", status: "pending").count
    assert_equal "override_superseded", first.notification_deliveries.find_by!(kind: "assignment_change", status: "pending").context.fetch("transition_type")
    assert_equal 2,
                 Munawaba::AuditEvent.where(shift_id: first.id,
                                            event_type: %w[override.created
                                                           override.superseded]).count
    execute(:revoke, first)
    newest = first.notification_deliveries.where(kind: "assignment_change", status: "pending").sole
    assert_equal "override_revoked", newest.context.fetch("transition_type")
    assert_nil first.reload.active_override
  end

  test "restoring the regular assignee records the ended override transition" do
    execute(:activate)
    first = @schedule.shifts.order(:boundary_index).first
    travel_to(first.starts_at + 1.minute)
    execute(:override, first, { person_id: @people[1].id })
    execute(:restore_to_base, first)
    delivery = first.notification_deliveries.where(kind: "assignment_change", status: "pending").sole
    assert_equal "override_restored_to_base", delivery.context.fetch("transition_type")
    assert Munawaba::Notifications::Validity.call(delivery).valid?
  end

  test "changing integration settings wakes the dispatcher once for the replacement intents" do
    execute(:activate)
    Munawaba::Notifications::WakeDispatcher.expects(:call).once
    result = Munawaba::Integrations.call(operation: :update, schedule: @schedule,
                                         attributes: { advance_notice_seconds: 3600 })
    assert result.success?, result.errors.inspect
  end

  test "a rotation emits one Next summary and preserves a future override matching its new base" do
    execute(:activate)
    first = @schedule.shifts.order(:boundary_index).first
    execute(:override, first, { person_id: @people[1].id })
    override = first.reload.active_override
    version = first.assignment_version
    execute(:rotation, @schedule, { person_ids: [@people[1].id, @people[0].id, @people[2].id] })
    assert_equal version, first.reload.assignment_version
    assert_equal override.id, first.active_override.id
    assert_equal 1, @schedule.notification_deliveries.where(kind: "next_assignment_change").count
    count = first.notification_deliveries.where(kind: "assignment_change").count
    execute(:revoke, first)
    assert_equal version, first.reload.assignment_version
    assert_equal count, first.notification_deliveries.where(kind: "assignment_change").count
    assert_empty first.notification_deliveries.where(kind: "assignment_change", status: "pending")
  end
  test "combined timing and rotation uses one conflict snapshot and plans only final assignment versions" do
    execute(:activate)
    period = Struct.new(:utc_total_offset).new(1800)
    zone = Object.new
    zone.define_singleton_method(:periods_for_local) { |_local| [period] }
    Munawaba::Timing::BoundaryCalculator.stubs(:timezone).returns(zone)
    attributes = { person_ids: @people.reverse.map(&:id) }
    proposed = Munawaba::Commands.preview(operation: :rotation, subject: @schedule, attributes: attributes,
                                          actor: actor)
    assert proposed.success?, proposed.errors.inspect
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      statements << payload[:sql] if payload[:name] == "Munawaba conflicts"
    end
    result = Munawaba::Commands.call(operation: :rotation, subject: @schedule, attributes: attributes, actor: actor,
                                     token: proposed.preview.token, acknowledge_conflicts: true)
    assert result.success?, result.errors.inspect
    assert_equal 1, statements.length
    assert_empty @schedule.notification_deliveries.where(timing_version: 2, status: "stale")
    @schedule.notification_deliveries.where(timing_version: 2).where.not(shift_id: nil).includes(:shift).each do |delivery|
      assert_equal delivery.shift.assignment_version, delivery.assignment_version
    end
    timing = Munawaba::AuditEvent.find_by!(event_type: "timing.future_projection_recomputed")
    rotation = Munawaba::AuditEvent.find_by!(event_type: "rotation.replaced")
    assert_operator @schedule.notification_deliveries.where(timing_version: 2).count, :>, 0
    assert_equal 1, @schedule.notification_deliveries.where(kind: "next_assignment_change", status: "pending").count
    assert_equal timing.operation_id, rotation.operation_id
    assert_nil timing.actor_id
    assert_equal actor.values_at(:type, :id, :name), rotation.attributes.values_at("actor_type", "actor_id", "actor_name")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "preserved override does not announce a change when regular Next stays the same" do
    execute(:activate)
    first = @schedule.shifts.order(:boundary_index).first
    execute(:override, first, { person_id: @people[2].id })
    explicit_override = first.reload.active_override.id
    assert_no_difference "@schedule.notification_deliveries.where(kind: 'next_assignment_change').count" do
      execute(:rotation, @schedule, { person_ids: [@people[0].id, @people[2].id, @people[1].id] })
    end
    assert_equal @people[0].id, first.reload.base_person_id
    assert_equal @people[2].id, first.effective_person_id
    assert_equal explicit_override, first.active_override.id
  end

  test "late override failure restores prior override assignment and deliveries within a host transaction" do
    execute(:activate)
    first = @schedule.shifts.order(:boundary_index).first
    execute(:override, first, { person_id: @people[1].id })
    old_override = first.reload.active_override
    old_deliveries = first.notification_deliveries.order(:id).pluck(:id, :status)
    attributes = { person_id: @people[2].id }
    proposed = Munawaba::Commands.preview(operation: :override, subject: first, attributes: attributes, actor: actor)
    Munawaba::Audit::Recorder.stubs(:record!).raises(ActiveRecord::RecordInvalid.new(Munawaba::AuditEvent.new))
    ActiveRecord::Base.transaction do
      assert_no_difference ["Munawaba::ShiftOverride.count", "Munawaba::NotificationDelivery.count",
                            "Munawaba::AuditEvent.count"] do
        result = Munawaba::Commands.call(operation: :override, subject: first, attributes: attributes,
                                         token: proposed.preview.token, acknowledge_conflicts: true)
        assert_equal 422, result.status
      end
      assert_equal @people[1].id, first.reload.effective_person_id
      assert_nil old_override.reload.ended_at
      assert_equal old_deliveries, first.notification_deliveries.order(:id).pluck(:id, :status)
    end
  end
end
