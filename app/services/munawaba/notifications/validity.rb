# frozen_string_literal: true

module Munawaba
  module Notifications
    class Validity
      Result = Struct.new(:status, :code, :schedule, :shift, keyword_init: true) do
        def valid? = status.nil?
      end
      KIND_SETTINGS = { "advance_reminder" => :notify_advance, "shift_start" => :notify_shift_start,
                        "assignment_change" => :notify_assignment_change, "next_assignment_change" => :notify_next_assignment_change }.freeze

      def self.call(delivery, now: Time.current, allow_old_notification_revision: false)
        # Bypass earlier cached reads so sending and lease recovery see committed changes.
        ActiveRecord::Base.uncached do
          validate(delivery, now: now, allow_old_notification_revision: allow_old_notification_revision)
        end
      end

      def self.validate(delivery, now:, allow_old_notification_revision:)
        context = Context::V1.validate!(kind: delivery.kind, context: delivery.context)
        schedule = Schedule.find(delivery.schedule_id)
        result = Result.new(schedule: schedule)
        reject = ->(status, code) { result.status = status; result.code = code; result }
        return reject.call(:stale, "expired") if delivery.expires_at <= now
        return reject.call(:canceled,
                           "integration_disabled") unless schedule.slack_enabled && schedule.slack_webhook_configured_at
        unless allow_old_notification_revision || delivery.notification_revision == schedule.notification_revision
          return reject.call(:stale, "notification_changed")
        end

        setting = KIND_SETTINGS[delivery.kind]
        return reject.call(:canceled, "kind_disabled") if setting && !schedule.public_send(setting)
        return result if delivery.kind == "test"
        return reject.call(:stale, "coverage_changed") unless delivery.coverage_revision == schedule.coverage_revision
        return reject.call(:canceled, "schedule_inactive") unless %w[scheduled active pausing].include?(schedule.state)

        shift = Shift.find(delivery.shift_id || context.fetch("described_shift_id"))
        result.shift = shift
        return reject.call(:canceled, "shift_canceled") if shift.canceled_at
        return reject.call(:stale,
                           "shift_changed") unless shift.schedule_id == schedule.id && shift.coverage_revision == schedule.coverage_revision
        return reject.call(:stale, "timing_changed") unless shift.timing_version == delivery.timing_version

        if delivery.kind == "next_assignment_change"
          return reject.call(:stale, "rotation_changed") unless schedule.rotation_revision == delivery.rotation_revision
          raise Context::V1::Invalid unless shift.base_person_id == context["new_next_person_id"] && shift.id == context["described_shift_id"]

          Person.find(context.fetch("previous_next_person_id"))
          Person.find(context.fetch("new_next_person_id"))
        else
          return reject.call(:stale,
                             "assignment_changed") unless delivery.assignment_version == shift.assignment_version

          validate_transition!(context, shift) if delivery.kind == "assignment_change"
        end
        unless Timing::PersistedIntervalVerifier.valid?(shift: shift, now: now)
          return reject.call(:stale, "timing_rules_changed")
        end

        result
      rescue Context::V1::Invalid, ActiveRecord::RecordNotFound, KeyError
        Result.new(status: :stale, code: "invalid_delivery_context")
      end

      def self.validate_transition!(context, shift)
        previous = Person.find(context.fetch("previous_person_id"))
        current = Person.find(context.fetch("new_person_id"))
        raise Context::V1::Invalid unless current.id == shift.effective_person_id

        replacement = ShiftOverride.find(context["override_id"]) if context["override_id"]
        ended = ShiftOverride.find(context["ended_override_id"]) if context["ended_override_id"]
        if replacement
          raise Context::V1::Invalid unless replacement.shift_id == shift.id && replacement.ended_at.nil? && replacement.previous_person_id == previous.id && replacement.replacement_person_id == current.id
        end
        if ended
          raise Context::V1::Invalid unless ended.shift_id == shift.id && ended.ended_at && ended.replacement_person_id == previous.id

          expected_reason = { "override_superseded" => "superseded", "override_revoked" => "revoked",
                              "override_restored_to_base" => "restored_to_base" }.fetch(context["transition_type"])
          raise Context::V1::Invalid unless ended.end_reason == expected_reason
        end
        if !replacement && shift.base_person_id != current.id
          raise Context::V1::Invalid
        end

        true
      end
    end
  end
end
