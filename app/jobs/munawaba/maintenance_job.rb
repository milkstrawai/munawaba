# frozen_string_literal: true

module Munawaba
  # Run every minute, or repair the timing of one schedule after a delivery mismatch.
  class MaintenanceJob < ApplicationJob
    def perform(schedule_id = nil)
      failure = nil
      scope = Schedule.where(state: schedule_id ? %w[scheduled active pausing] : %w[scheduled pausing])
      scope = scope.where(id: schedule_id) if schedule_id
      scope.find_each(batch_size: 100) do |schedule|
        Shifts::NormalizeFutureTiming.call(schedule: schedule)
      rescue StandardError => error
        failure ||= error
        Munawaba.signal("maintenance_failed", task: "lifecycle", schedule_id: schedule.id)
      end

      unless schedule_id
        [Notifications::ReclaimExpiredLeases, Notifications::Dispatcher].each do |task|
          task.call
        rescue StandardError => error
          failure ||= error
          Munawaba.signal("maintenance_failed", task: task.name)
        end
      end
      raise failure if failure
    end
  end
end
