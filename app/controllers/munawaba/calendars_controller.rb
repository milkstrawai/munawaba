# frozen_string_literal: true

module Munawaba
  class CalendarsController < ApplicationController
    def show
      %i[date until schedule_id person_id view].each { |key| scalar_parameter(key) }
      @schedules = Schedule.order(:name)
      @people = Person.order(:name)
      @schedule = Schedule.find_by(id: params[:schedule_id]) if params[:schedule_id].present?
      @time_zone = @schedule&.time_zone || Munawaba.config.organization_time_zone
      zone = ActiveSupport::TimeZone[@time_zone]
      today = Time.current.in_time_zone(zone).to_date
      @view = params[:view] == "month" ? "month" : "agenda"
      @date = params[:date].present? ? Date.iso8601(params[:date]) : today
      @from = @view == "month" ? @date.beginning_of_month : @date
      @until = params[:until].present? ? Date.iso8601(params[:until]) : (@view == "month" ? @from.next_month : @from + 28)
      floor = (Time.current - Munawaba.config.calendar_past_limit).in_time_zone(zone).to_date
      ceiling = (Time.current + Munawaba.config.calendar_future_limit).in_time_zone(zone).to_date
      raise ArgumentError,
            "Choose dates within the calendar window." if @from < floor || @from > ceiling || @until <= @from || @until > ceiling + 1
      raise ArgumentError, "The calendar range is too long." if @until > (@from + Munawaba.config.calendar_max_span)

      start_at = zone.local(@from.year, @from.month, @from.day)
      end_at = zone.local(@until.year, @until.month, @until.day)
      @shifts = Shift.live.overlapping(start_at, end_at)
      @shifts = @shifts.where(schedule_id: params[:schedule_id]) if params[:schedule_id].present?
      @shifts = @shifts.where(effective_person_id: params[:person_id]) if params[:person_id].present?
      @shifts = @shifts.includes(:schedule, :base_person, :effective_person).order(:starts_at, :id).to_a
      @previous_date = @view == "month" ? @from.prev_month : @from - 28
      @next_date = @view == "month" ? @from.next_month : @from + 28
      @previous_date = nil if @previous_date < floor
      @next_date = nil if (@view == "month" ? @next_date.next_month : @next_date + 28) > ceiling + 1
    rescue ArgumentError => error
      @errors = [error.message == "invalid date" ? "Enter a valid calendar date." : error.message]
      @shifts = []
      @from ||= today
      @until ||= @from + 28
      render :show, status: :unprocessable_entity
    end

    private

    def authorization_target
      [:read, :calendar]
    end
  end
end
