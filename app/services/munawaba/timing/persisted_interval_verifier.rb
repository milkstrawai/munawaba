# frozen_string_literal: true

module Munawaba
  module Timing
    class PersistedIntervalVerifier
      def self.valid?(shift:, now:, provider: Timing::BoundaryCalculator.method(:timezone))
        return false if shift.canceled_at || shift.coverage_revision != shift.schedule.coverage_revision

        # Started shifts keep their saved times. Check future shifts with the same
        # boundary and start rules used when preparing a scheduling change.
        if shift.starts_at <= now
          calculator = BoundaryCalculator.new(shift.schedule, provider: provider)
          changed = calculator.boundary(shift.boundary_index + 1).resolved_at != shift.ends_at
          ActiveSupport::Notifications.instrument("timing.frozen_interval_rule_change.munawaba",
                                                  schedule_id: shift.schedule_id, shift_id: shift.id) if changed
          return !changed
        end
        prepared = Shifts::NormalizeFutureTiming.prepare(schedule: shift.schedule, now: now, provider: provider)
        virtual = prepared.slots.find { |slot| slot[:id] == shift.id }
        virtual && virtual[:starts_at] == shift.starts_at && virtual[:ends_at] == shift.ends_at && !prepared.clipping
      rescue ArgumentError, TZInfo::InvalidTimezoneIdentifier
        false
      end
    end
  end
end
