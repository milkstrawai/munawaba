# frozen_string_literal: true

module Munawaba
  module Shifts
    class Project
      def self.call(schedule:, observed_revision: nil, now: nil)
        operation_id = SecureRandom.uuid
        ActiveRecord::Base.transaction(requires_new: true) do
          schedule.lock!("FOR NO KEY UPDATE")
          captured = now ? Canonical.time(now) : Canonical.time(Time.current)
          next [] unless %w[scheduled active].include?(schedule.state)
          next [] if observed_revision && schedule.coverage_revision != observed_revision

          prepared = NormalizeFutureTiming.locked_preparation(schedule, captured)
          NormalizeFutureTiming.apply!(prepared, now: captured, operation_id: operation_id)
          next [] unless %w[scheduled active].include?(schedule.state)

          calculator = Timing::BoundaryCalculator.new(schedule)
          target = ProjectionPlan.target(calculator, schedule.coverage_start_boundary,
                                         captured + Defaults::SHIFT_GENERATION_HORIZON)
          cursor = schedule.generated_through_boundary
          next [] if cursor >= target

          ids = schedule.ordered_person_ids
          raise ArgumentError,
                "A live schedule requires active rotation members" if ids.empty? || Person.active.where(id: ids).count != ids.length

          last = prepared.slots.max_by { |slot| slot[:boundary_index] }
          slots = ((cursor + 1)..target).map do |index|
            person_id = ids[(index - schedule.rotation_effective_boundary) % ids.length]
            start = index == cursor + 1 && last ? last[:ends_at] : calculator.boundary(index).resolved_at
            { id: nil, schedule_id: schedule.id, coverage_revision: schedule.coverage_revision, boundary_index: index,
              starts_at: start, ends_at: calculator.boundary(index + 1).resolved_at,
              base_person_id: person_id, effective_person_id: person_id, rotation_revision: schedule.rotation_revision, assignment_version: 1, timing_version: 1 }
          end
          conflicts = Conflicts::Finder.call(slots: slots)
          rows = Shift.persist_projection!(schedule: schedule, slots: slots, now: captured)
          schedule.update!(generated_through_boundary: target)
          Notifications::Planner.call(schedule: schedule, now: captured, operation: "project", shifts: rows)
          Audit::Recorder.record!(event_type: "timing.projection_extended", schedule: schedule,
                                  operation_id: operation_id, occurred_at: captured,
                                  metadata: { inserted_count: rows.length, projected_until: rows.last.ends_at })
          ActiveSupport::Notifications.instrument("projection.conflicts.munawaba", schedule_id: schedule.id,
                                                                                   conflict_count: conflicts.length) if conflicts.any?
          rows
        end
      end
    end
  end
end
