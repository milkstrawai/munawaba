# frozen_string_literal: true

module Munawaba
  module Notifications
    class RetryFailed
      def self.call(delivery:, actor: nil, acknowledge_duplicate: false)
        reference = NotificationDelivery.uncached { NotificationDelivery.find(delivery.id) }
        parsed = Context::V1.validate!(kind: reference.kind, context: reference.context)
        described_shift_id = reference.shift_id || parsed["described_shift_id"]
        result = nil
        NotificationDelivery.transaction(requires_new: true) do
          schedule = Schedule.where(id: reference.schedule_id).lock("FOR NO KEY UPDATE").first!
          shift = Shift.where(id: described_shift_id).lock("FOR NO KEY UPDATE").first! if described_shift_id
          original = NotificationDelivery.where(id: reference.id).lock("FOR NO KEY UPDATE").first!
          authoritative_context = Context::V1.validate!(kind: original.kind, context: original.context)
          unless original.schedule_id == schedule.id &&
                 (original.shift_id || authoritative_context["described_shift_id"]) == described_shift_id &&
                 (!shift || shift.schedule_id == schedule.id)
            raise Context::V1::Invalid
          end

          now = Time.current
          validity = Validity.call(original, now: now, allow_old_notification_revision: true)
          if original.status != "failed" || !validity.valid? || NotificationDelivery.exists?(retry_of_delivery_id: original.id)
            result = Result.new(status: 422, record: original,
                                errors: ["This delivery is no longer eligible for retry."])
            next
          end
          if original.last_error_code == "delivery_outcome_unknown" && !ActiveModel::Type::Boolean.new.cast(acknowledge_duplicate)
            result = Result.new(status: 422, record: original,
                                errors: ["Acknowledge that retrying may post a duplicate message."])
            next
          end
          values = original.attributes.slice("shift_id", "kind", "coverage_revision", "assignment_version",
                                             "timing_version", "rotation_revision", "expires_at")
          successor = NotificationDelivery.create!(**values, schedule: schedule, retry_of_delivery_id: original.id,
                                                             notification_revision: schedule.notification_revision, context: authoritative_context, event_key: "retry:#{original.id}:#{SecureRandom.uuid}",
                                                             status: "pending", due_at: now, next_attempt_at: now)
          Audit::Recorder.record!(event_type: "notification.manual_retry_requested", schedule: schedule, shift_id: original.shift_id,
                                  actor: actor, occurred_at: now, metadata: { predecessor_delivery_id: original.id, successor_delivery_id: successor.id,
                                                                              kind: original.kind })
          WakeDispatcher.call
          result = Result.new(status: 303, record: successor, errors: [])
        end
        result
      rescue Context::V1::Invalid, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
        Result.new(status: 422, record: delivery, errors: ["This delivery cannot be retried."])
      end
    end
  end
end
