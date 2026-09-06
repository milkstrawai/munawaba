# frozen_string_literal: true

module Munawaba
  # Run daily, or enqueue a single schedule after a scheduling change.
  class MaintainProjectionJob < ApplicationJob
    def perform(schedule_id = nil, observed_revision = nil)
      scope = Schedule.where(state: %w[scheduled active pausing])
      scope = scope.where(id: schedule_id) if schedule_id
      failure = nil
      scope.find_each(batch_size: 100) do |schedule|
        if schedule.state == "pausing"
          next if observed_revision

          Shifts::NormalizeFutureTiming.call(schedule: schedule)
        else
          Shifts::Project.call(schedule: schedule, observed_revision: observed_revision)
        end
      rescue StandardError => error
        failure ||= error
        Munawaba.signal("maintenance_failed", task: "projection", schedule_id: schedule.id)
      end
      raise failure if failure
    end
  end
end
