# frozen_string_literal: true

module Munawaba
  module Shifts
    class NormalizeFutureTiming
      SCHEDULE_FIELDS = %w[state coverage_starts_at first_activated_at lifecycle_revision coverage_start_boundary
                           generated_through_boundary rotation_effective_boundary pause_effective_at].freeze
      Prepared = Struct.new(:schedule, :virtual_schedule, :rows, :slots, :changes,
                            :clipping, :conflicts, :audit_before, :finalized, keyword_init: true) do
        def changed? = changes.any? || SCHEDULE_FIELDS.any? { |key| schedule[key] != virtual_schedule[key] }
      end
      SLOT_FIELDS = %i[id schedule_id coverage_revision boundary_index starts_at ends_at base_person_id
                       effective_person_id rotation_revision assignment_version timing_version].freeze

      def self.call(schedule:, now: nil)
        ActiveRecord::Base.transaction(requires_new: true) do
          schedule.lock!("FOR NO KEY UPDATE")
          captured = Canonical.time(now || Time.current)
          prepared = locked_preparation(schedule, captured)
          apply!(prepared, now: captured)
          prepared
        end
      end

      def self.locked_preparation(schedule, now)
        live = Shift.where(schedule_id: schedule.id, coverage_revision: schedule.coverage_revision, canceled_at: nil)
        # The latest started shift fixes the boundary with coverage already underway.
        ids = case schedule.state
              when "scheduled", "active"
                future_ids = live.where("starts_at > ?", now).pluck(:id)
                if schedule.state == "active" || schedule.coverage_starts_at <= now
                  preceding_id = live.where("starts_at <= ?", now).order(starts_at: :desc, id: :desc).pick(:id)
                end
                first_id = live.where(boundary_index: schedule.coverage_start_boundary).pick(:id) if schedule.state == "scheduled"
                future_ids + [preceding_id, first_id].compact
              when "pausing"
                live.where(boundary_index: schedule.generated_through_boundary).pluck(:id)
              else []
              end
        shifts = live.where(id: ids.uniq).order(:id).lock("FOR NO KEY UPDATE").to_a
        ShiftOverride.where(shift_id: shifts.map(&:id), ended_at: nil).order(:id).lock("FOR NO KEY UPDATE").load
        NotificationDelivery.where(schedule_id: schedule.id,
                                   status: %w[pending enqueued
                                              processing]).order(:id).lock("FOR NO KEY UPDATE").load
        prepare(schedule: schedule, now: now, shifts: shifts)
      end

      def self.slot(shift)
        SLOT_FIELDS.to_h { |key| [key, shift.public_send(key)] }
      end

      def self.prepare(schedule:, now:, shifts: nil, provider: Timing::BoundaryCalculator.method(:timezone))
        rows = shifts || Shift.where(schedule_id: schedule.id, coverage_revision: schedule.coverage_revision,
                                     canceled_at: nil).order(:id).to_a
        rows = rows.select { |row|
          row.canceled_at.nil? && row.coverage_revision == schedule.coverage_revision
        }.sort_by(&:boundary_index)
        virtual = schedule.dup
        virtual.id = schedule.id
        slots = rows.map { |row| slot(row) }
        changes = []
        clipping = false
        if %w[scheduled active].include?(schedule.state) && rows.any?
          calculator = Timing::BoundaryCalculator.new(schedule, provider: provider)
          first = rows.first
          scheduled = schedule.state == "scheduled"
          first_new_start = calculator.boundary(first.boundary_index).resolved_at
          # If a changed rule moves the start into the past, begin at now instead
          # of creating coverage for time that has already passed.
          scheduled_moved = scheduled && first_new_start != schedule.coverage_starts_at
          clipping = scheduled_moved && first_new_start <= now
          slots.each_with_index do |item, index|
            next unless item[:starts_at] > now || scheduled_moved

            left = calculator.boundary(item[:boundary_index]).resolved_at
            right = calculator.boundary(item[:boundary_index] + 1).resolved_at
            prior = index.positive? && slots[index - 1]
            left = prior[:ends_at] if prior && (prior[:starts_at] <= now || scheduled_moved)
            left = now if clipping && index.zero?
            raise ArgumentError, "Timing maintenance is required: an interval is no longer positive" unless right > left

            if item[:starts_at] != left || item[:ends_at] != right
              item[:starts_at] = left
              item[:ends_at] = right
              item[:timing_version] += 1
              changes << item
            end
          end
          if scheduled
            start = slots.first[:starts_at]
            moved = start != schedule.coverage_starts_at
            virtual.coverage_starts_at = start
            if start <= now
              virtual.state = "active"
              virtual.first_activated_at ||= start
            end
            virtual.lifecycle_revision += 1 if moved || virtual.state != schedule.state
          end
        elsif schedule.state == "pausing" && schedule.pause_effective_at <= now
          virtual.assign_attributes(state: "paused", coverage_start_boundary: nil, coverage_starts_at: nil,
                                    generated_through_boundary: nil, rotation_effective_boundary: nil, pause_effective_at: nil,
                                    lifecycle_revision: schedule.lifecycle_revision + 1)
        end
        slots.each_cons(2) do |left, right|
          raise ArgumentError,
                "Timing maintenance would overlap retained intervals" if left[:ends_at] > right[:starts_at]
        end
        Prepared.new(schedule: schedule, virtual_schedule: virtual, rows: rows, slots: slots,
                     changes: changes, clipping: clipping)
      end

      # Keep preparation separate so confirmations can verify the signed preview
      # and its conflicts before changing stored shifts.
      def self.apply!(prepared, now:, operation_id: SecureRandom.uuid, defer: false)
        schedule = prepared.schedule
        prepared.audit_before = { start: schedule.coverage_starts_at, state: schedule.state,
                                  pause: schedule.pause_effective_at, first_ever: schedule.first_activated_at.nil? }
        Shift.connection.execute("SET CONSTRAINTS ALL DEFERRED") if prepared.changes.any?
        prepared.changes.each do |slot|
          prepared.rows.find { |row|
            row.id == slot[:id]
          }.update!(starts_at: slot[:starts_at], ends_at: slot[:ends_at], timing_version: slot[:timing_version])
        end
        changes = SCHEDULE_FIELDS.select { |key| prepared.schedule[key] != prepared.virtual_schedule[key] }
        prepared.schedule.update!(prepared.virtual_schedule.attributes.slice(*changes)) if changes.any?
        finalize!(prepared, now: now, operation_id: operation_id) unless defer
        prepared
      end

      # Combined changes publish timing effects after the final assignments are saved.
      def self.finalize!(prepared, now:, operation_id:)
        return if prepared.finalized

        prepared.finalized = true
        schedule = prepared.schedule
        before_start, before_state, before_pause, first_ever = prepared.audit_before.values_at(:start, :state, :pause, :first_ever)
        audit_attributes = { schedule: schedule, operation_id: operation_id, occurred_at: now }

        if prepared.changes.any?
          conflicts = prepared.conflicts || Conflicts::Finder.call(slots: prepared.changes)
          rows = Shift.where(id: prepared.changes.map { |slot| slot[:id] }).order(:id).to_a
          Notifications::Planner.call(schedule: schedule, now: now, operation: "timing", shifts: rows,
                                      invalidation_shift_ids: rows.map(&:id))
          if conflicts.any?
            ActiveSupport::Notifications.instrument("timing.conflicts.munawaba", schedule_id: schedule.id,
                                                                                 conflict_count: conflicts.length)
          end
          Audit::Recorder.record!(**audit_attributes, event_type: "timing.future_projection_recomputed", metadata: {
                                    changed_count: rows.length,
                                    coverage_starts_at_before: Canonical.instant(before_start),
                                    coverage_starts_at_after: Canonical.instant(schedule.coverage_starts_at),
                                    state_before: before_state, state_after: schedule.state
                                  })
        end

        if before_state == "scheduled" && schedule.state == "active"
          first = prepared.rows.min_by(&:boundary_index)
          event = first_ever ? "schedule.activated" : "schedule.resumed"
          Audit::Recorder.record!(**audit_attributes, event_type: event, shift: first, metadata: {
                                    state_before: before_state, state_after: schedule.state,
                                    coverage_starts_at: schedule.coverage_starts_at, next_person_id: first.base_person_id
                                  })
        elsif before_state == "pausing" && schedule.state == "paused"
          last = prepared.rows.max_by(&:boundary_index)
          Audit::Recorder.record!(**audit_attributes, event_type: "schedule.paused", shift: last, metadata: {
                                    state_before: before_state, state_after: schedule.state, effective_at: before_pause
                                  })
        end
      end
    end
  end
end
