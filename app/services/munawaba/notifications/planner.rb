# frozen_string_literal: true

module Munawaba
  module Notifications
    class Planner
      def self.call(schedule:, now:, operation:, shifts: [], previous_person_id: nil, override: nil,
                    ended_override: nil, invalidation_shift_ids: nil)
        new(schedule, now).call(operation: operation.to_s, shifts: shifts, previous_person_id: previous_person_id,
                                override: override, ended_override: ended_override, invalidation_shift_ids: invalidation_shift_ids)
      end

      def initialize(schedule, now)
        @schedule, @now = schedule, now
        @planned_count = 0
      end

      def call(operation:, shifts:, previous_person_id:, override:, ended_override:,
               invalidation_shift_ids: nil)
        invalidate(invalidation_shift_ids)
        rows = shifts.present? ? shifts : @schedule.shifts.live.where(coverage_revision: @schedule.coverage_revision).where(
          "ends_at > ?", @now
        ).order(:id)
        rows = rows.to_a
        rows.each { |shift| plan_shift(shift) }
        if %w[override revoke restore_to_base].include?(operation) && previous_person_id && rows.one?
          plan_assignment(rows.first, previous_person_id, override, ended_override)
        elsif %w[rotation deactivate].include?(operation) && previous_person_id
          shift = @schedule.shifts.live.where(coverage_revision: @schedule.coverage_revision).where("starts_at > ?", @now).order(
            :starts_at, :id
          ).first
          plan_next(shift, previous_person_id) if shift
        end
        WakeDispatcher.call if @planned_count.positive?
        @planned_count
      end

      def enabled?(kind)
        return false unless @schedule.slack_webhook_configured_at
        return false unless @schedule.slack_enabled

        setting = Validity::KIND_SETTINGS[kind]
        return false if setting && !@schedule.public_send(setting)

        true
      end

      def invalidate(shift_ids = nil)
        scope = @schedule.notification_deliveries.unsent
        if shift_ids
          # Compare JSON IDs as text so malformed context cannot cause a SQL cast error.
          scope = scope.where(
            "shift_id IN (?) OR (kind = 'next_assignment_change' AND context->>'described_shift_id' IN (?))", shift_ids, shift_ids.map(&:to_s)
          )
        end
        scope.order(:id).lock("FOR NO KEY UPDATE").each do |delivery|
          validity = Validity.call(delivery, now: @now)
          next if validity.valid?

          replan_transition(delivery) if validity.code == "timing_changed"
          delivery.finish!(status: validity.status, code: validity.code, now: @now)
        end
      end

      def plan_shift(shift)
        return if shift.canceled_at || shift.ends_at <= @now || shift.coverage_revision != @schedule.coverage_revision
        return unless %w[scheduled active pausing].include?(@schedule.state)

        create_shift_intent(shift, "advance_reminder", due_at: shift.starts_at - @schedule.advance_notice_seconds,
                                                       expires_at: shift.starts_at)
        create_shift_intent(shift, "shift_start", due_at: shift.starts_at,
                                                  expires_at: shift.starts_at + Munawaba::Defaults::START_NOTIFICATION_GRACE_PERIOD)
      end

      def create_shift_intent(shift, kind, due_at:, expires_at:, context: Context::V1.build(kind: kind))
        return unless enabled?(kind)
        return if expires_at <= @now

        key = "shift:#{shift.id}:#{kind}:assignment:#{shift.assignment_version}:timing:#{shift.timing_version}:notification:#{@schedule.notification_revision}"
        create(kind: kind, event_key: key, shift_id: shift.id, coverage_revision: shift.coverage_revision,
               assignment_version: shift.assignment_version, timing_version: shift.timing_version,
               context: context, due_at: [due_at, expires_at - 0.000001].min, expires_at: expires_at)
      end

      def plan_assignment(shift, previous, override, ended)
        return if previous.to_i == shift.effective_person_id

        transition = ended ? "override_#{ended.end_reason}" : "override_created"
        values = { transition_type: transition, previous_person_id: previous.to_i,
                   new_person_id: shift.effective_person_id }
        values[:override_id] = override.id if override
        values[:ended_override_id] = ended.id if ended
        origin = override&.created_at || ended&.ended_at
        return unless origin

        context = Context::V1.build(kind: "assignment_change", **values)
        create_shift_intent(shift, "assignment_change", due_at: origin,
                                                        expires_at: [shift.ends_at, origin + 24.hours].min, context: context)
      end

      def plan_next(shift, previous)
        return if previous.to_i == shift.base_person_id
        return unless enabled?("next_assignment_change")

        expires_at = [shift.starts_at, @now + 24.hours].min
        return if expires_at <= @now

        context = Context::V1.build(kind: "next_assignment_change",
                                    previous_next_person_id: previous.to_i, new_next_person_id: shift.base_person_id, described_shift_id: shift.id)
        create(kind: "next_assignment_change", event_key: next_key(shift), context: context, coverage_revision: shift.coverage_revision,
               rotation_revision: @schedule.rotation_revision, timing_version: shift.timing_version, due_at: @now, expires_at: expires_at)
      end

      def next_key(shift)
        "schedule:#{@schedule.id}:next_assignment_change:coverage:#{@schedule.coverage_revision}:rotation:#{@schedule.rotation_revision}:timing:#{shift.timing_version}:notification:#{@schedule.notification_revision}"
      end

      def replan_transition(delivery)
        return unless %w[assignment_change next_assignment_change].include?(delivery.kind)
        return unless enabled?(delivery.kind)

        context = Context::V1.validate!(kind: delivery.kind, context: delivery.context)
        shift = Shift.find(delivery.shift_id || context.fetch("described_shift_id"))
        candidate = delivery.dup
        candidate.timing_version = shift.timing_version
        candidate.notification_revision = @schedule.notification_revision
        return unless Validity.call(candidate, now: @now).valid?

        if delivery.kind == "assignment_change"
          transition = ShiftOverride.find(context["override_id"] || context.fetch("ended_override_id"))
          origin = context["override_id"] ? transition.created_at : transition.ended_at
          create_shift_intent(shift, delivery.kind, due_at: origin, expires_at: [shift.ends_at, origin + 24.hours].min,
                                                    context: context)
        else
          expiry = [shift.starts_at, delivery.created_at + 24.hours].min
          return if expiry <= @now

          create(kind: delivery.kind, event_key: next_key(shift), context: context, coverage_revision: shift.coverage_revision,
                 rotation_revision: @schedule.rotation_revision, timing_version: shift.timing_version, due_at: delivery.due_at, expires_at: expiry)
        end
      rescue Context::V1::Invalid, ActiveRecord::RecordNotFound
        nil
      end

      def create(**attributes)
        return if NotificationDelivery.exists?(event_key: attributes.fetch(:event_key))

        row = NotificationDelivery.create!(**attributes, schedule_id: @schedule.id, notification_revision: @schedule.notification_revision,
                                                         status: "pending", next_attempt_at: [attributes.fetch(:due_at), @now].max)
        @planned_count += 1
        row
      end
    end
  end
end
