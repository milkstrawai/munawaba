require "test_helper"

class NextAssignmentContextTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 9, 5, 12)
    @people = 3.times.map { |i| Munawaba::Person.create!(name: "Person #{i}", email: "next#{i}@example.org") }
    @schedule = Munawaba::Schedule.create!(name: "Historical Next", cadence: "one_week", time_zone: "UTC",
                                           anchor_local_date: Date.new(2026, 9, 4), anchor_local_seconds: 0, slack_enabled: true, slack_webhook_url: "https://hooks.slack.com/services/TEAM/CHANNEL/next-test", slack_webhook_configured_at: Time.current)
    @people.each_with_index { |person, position| Munawaba::ScheduleMembership.create!(schedule: @schedule, person: person, position: position) }
    confirm(:activate)
    confirm(:rotation, person_ids: [@people[2].id, @people[0].id, @people[1].id])
    @delivery = @schedule.notification_deliveries.where(kind: "next_assignment_change").sole
    @original_context = @delivery.context.deep_dup
  end

  teardown { travel_back }

  test "next assignment keeps its before and after snapshot when activity is cleaned up" do
    assert_equal @people[1].id, @delivery.context["previous_next_person_id"]
    assert_equal @people[2].id, @delivery.context["new_next_person_id"]
    refute @delivery.context.key?("operation_id")
    clear_activity!

    assert Munawaba::Notifications::Validity.call(@delivery).valid?
    message = Munawaba::Slack::Renderer.call(delivery: @delivery, schedule: @schedule)
    assert_includes message.fetch(:text), "Person 1 → Person 2"
  end

  test "next assignment becomes stale when its rotation changes" do
    @schedule.increment!(:rotation_revision)
    result = Munawaba::Notifications::Validity.call(@delivery)
    assert_equal :stale, result.status
    assert_equal "rotation_changed", result.code
  end

  test "manual retry rejects a snapshot that no longer matches the current assignment" do
    fail_delivery!
    @delivery.update_columns(context: @original_context.merge("new_next_person_id" => @people[0].id))
    assert_no_difference ["Munawaba::NotificationDelivery.count", "Munawaba::AuditEvent.count"] do
      result = Munawaba::Notifications::RetryFailed.call(delivery: @delivery, actor: actor)
      assert_equal 422, result.status
    end
  end

  test "manual retry preserves the saved snapshot and expiry after activity cleanup" do
    fail_delivery!
    clear_activity!
    result = Munawaba::Notifications::RetryFailed.call(delivery: @delivery, actor: actor)
    assert_equal 303, result.status, result.errors.inspect
    assert_equal @original_context, result.record.context
    assert_equal @delivery.expires_at, result.record.expires_at
    assert_no_difference ["Munawaba::NotificationDelivery.count", "Munawaba::AuditEvent.count"] do
      duplicate = Munawaba::Notifications::RetryFailed.call(delivery: @delivery, actor: actor)
      assert_equal 422, duplicate.status
    end
  end

  test "deliveries created with the old activity reference still validate and retry" do
    @delivery.update_columns(context: @original_context.merge("operation_id" => SecureRandom.uuid))
    clear_activity!
    assert Munawaba::Notifications::Validity.call(@delivery.reload).valid?
    fail_delivery!
    result = Munawaba::Notifications::RetryFailed.call(delivery: @delivery, actor: actor)
    assert_equal 303, result.status, result.errors.inspect
    assert_equal @original_context, result.record.context
  end

  test "retry locks the described shift after its schedule and before the delivery leaf" do
    fail_delivery!
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      statements << payload[:sql] if payload[:sql].include?("FOR NO KEY UPDATE")
    end
    result = Munawaba::Notifications::RetryFailed.call(delivery: @delivery, actor: actor)
    assert_equal 303, result.status, result.errors.inspect
    tables = statements.filter_map { |sql| sql[/FROM "(munawaba_[^"]+)"/, 1] }
    assert_equal %w[munawaba_schedules munawaba_shifts munawaba_notification_deliveries], tables.first(3)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  private

  def clear_activity!
    assert_operator Munawaba::AuditEvent.where(schedule: @schedule).delete_all, :>, 0
  end

  def confirm(operation, attributes = {})
    preview = Munawaba::Commands.preview(operation: operation, subject: @schedule, attributes: attributes, actor: actor)
    assert preview.success?, preview.errors.inspect
    result = Munawaba::Commands.call(operation: operation, subject: @schedule, attributes: attributes, actor: actor,
                                     token: preview.preview.token, acknowledge_conflicts: true)
    assert result.success?, result.errors.inspect
    @schedule.reload
  end

  def fail_delivery!
    @delivery.update!(status: "failed", next_attempt_at: nil, last_error_code: "slack_rejected")
  end
end
