# frozen_string_literal: true

module Munawaba
  class OverviewsController < ApplicationController
    def show
      @schedules = Schedule.order(:name).to_a
      @now = Time.current
      candidates = Shift.where(canceled_at: nil).where("ends_at > ?", @now)
                        .select("id, row_number() OVER (PARTITION BY schedule_id ORDER BY starts_at, id) AS position")
      nearest_ids = Shift.from("(#{candidates.to_sql}) upcoming").where("position <= 2").select("id")
      @shifts = Shift.where(id: nearest_ids).order(:starts_at).includes(:effective_person).to_a.group_by(&:schedule_id)
      @projected_through = Shift.where(canceled_at: nil).group(:schedule_id).maximum(:ends_at)
      @roster_counts = ScheduleMembership.group(:schedule_id).count
    end

    private

    def authorization_target
      [:read, :overview]
    end
  end
end
