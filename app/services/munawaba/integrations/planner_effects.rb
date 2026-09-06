# frozen_string_literal: true

module Munawaba
  module Integrations
    class PlannerEffects
      def self.replace_epoch(schedule, old_intents, now)
        planned_count = 0
        old_intents.each do |row|
          valid = Notifications::Validity.call(row, now: now, allow_old_notification_revision: true)
          status = valid.status == :canceled ? :canceled : :stale
          if row.kind != "test" && valid.valid? && %w[assignment_change next_assignment_change].include?(row.kind)
            values = row.attributes.slice("shift_id", "kind", "coverage_revision", "assignment_version",
                                          "timing_version", "rotation_revision", "expires_at")
            context = Notifications::Context::V1.validate!(kind: row.kind, context: row.context)
            NotificationDelivery.create!(**values, schedule_id: schedule.id, notification_revision: schedule.notification_revision,
                                                   event_key: row.event_key.sub(/notification:\d+/, "notification:#{schedule.notification_revision}"), context: context,
                                                   due_at: now, next_attempt_at: now, status: "pending")
            planned_count += 1
          end
          row.finish!(status: status, code: valid.code || "notification_changed", now: now)
        end
        planned = Notifications::Planner.call(schedule: schedule, now: now, operation: "integration")
        Notifications::WakeDispatcher.call if planned_count.positive? && planned.zero?
      end
    end
  end
end
