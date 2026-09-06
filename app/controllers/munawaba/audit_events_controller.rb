# frozen_string_literal: true

module Munawaba
  class AuditEventsController < ApplicationController
    def index
      %i[schedule_id person_id shift_id actor_type actor_id event_type from until].each { |key| scalar_parameter(key) }
      scope = AuditEvent.all
      %i[schedule_id person_id shift_id actor_type actor_id event_type].each do |key|
        scope = scope.where(key => params[key]) if params[key].present?
      end
      scope = scope.where("occurred_at >= ?", Date.iso8601(params[:from]).beginning_of_day) if params[:from].present?
      scope = scope.where("occurred_at < ?",
                          Date.iso8601(params[:until]).next_day.beginning_of_day) if params[:until].present?
      @events = before_cursor(scope, "occurred_at").order(occurred_at: :desc, id: :desc).limit(page_size + 1).to_a
      @more = @events.size > page_size
      @events = @events.first(page_size)
      @schedules = Schedule.order(:name)
      @people = Person.order(:name)
    rescue ArgumentError
      @errors = ["Enter valid filter dates."]
      @events, @schedules, @people = [], Schedule.order(:name), Person.order(:name)
      render :index, status: :unprocessable_entity
    end

    private

    def authorization_target
      [:view_audit, :activity]
    end
  end
end
