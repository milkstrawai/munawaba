# frozen_string_literal: true

module Munawaba
  class SchedulesController < ApplicationController
    def index
      @schedules = after_name_cursor(Schedule.order(:name, :id)).limit(page_size + 1).to_a
      @more = @schedules.size > page_size
      @schedules = @schedules.first(page_size)
      @membership_counts = ScheduleMembership.where(schedule_id: @schedules.map(&:id)).group(:schedule_id).count
    end

    def show
      @memberships = computed_roster(@schedule,
                                     ScheduleMembership.where(schedule_id: @schedule.id).includes(:person).order(:position))
      @shifts = Shift.where(schedule_id: @schedule.id, canceled_at: nil).where("ends_at > ?", Time.current)
                     .includes(:effective_person, :base_person, :schedule).order(:starts_at).limit(100)
      @current_shift = @shifts.find { |shift| shift.starts_at <= Time.current && shift.ends_at > Time.current }
      prepare_resume_form if @schedule.state == "paused"
    end

    def new
      @schedule = Schedule.new(cadence: "one_week", time_zone: Munawaba.config.default_schedule_time_zone,
                               anchor_local_date: Date.current, anchor_local_seconds: 9 * 3600)
    end

    def create
      @schedule = Schedule.new(schedule_attributes)
      command(:create_schedule, @schedule, schedule_attributes, success_path: ->(record) {
        schedule_path(record)
      }, template: "new") do |result|
        @schedule = result.record if result.record.is_a?(Schedule)
      end
    end

    def edit; end

    def update
      command(:update_schedule, @schedule, schedule_attributes, success_path: schedule_path(@schedule),
                                                                template: "edit") do |_result|
        @schedule.assign_attributes(schedule_attributes.except(:lock_version))
      end
    end

    def preview_activation
      proposal(:activate, @schedule, lifecycle_attributes)
    end

    def preview_resume
      if params[:edit_order] == "add"
        prepare_resume_form
        render :resume
        return
      end
      proposal(:resume, @schedule, lifecycle_attributes)
    end

    def activate
      confirm_lifecycle(:activate)
    end

    def resume
      confirm_lifecycle(:resume)
    end

    def pause
      return proposal(:pause, @schedule, lifecycle_attributes) if params[:proposal_token].blank?

      confirm_lifecycle(:pause)
    end

    def cancel_scheduled
      return proposal(:cancel_scheduled, @schedule, lifecycle_attributes) if params[:proposal_token].blank?

      confirm_lifecycle(:cancel_scheduled)
    end

    private

    def authorization_target
      @schedule = Schedule.find(params[:id]) if params[:id]
      [(%w[index show].include?(action_name) ? :read : :manage_schedules), @schedule || Schedule]
    end

    def schedule_attributes
      attributes = record_parameters(:schedule).permit(:name, :cadence, :time_zone, :anchor_local_date,
                                                       :anchor_local_time, :lock_version).to_h.symbolize_keys
      if attributes.key?(:anchor_local_time)
        value = attributes.delete(:anchor_local_time).to_s
        attributes[:anchor_local_seconds] = value.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/) ? value.split(":").map(&:to_i).then { |h, m|
          (h * 3600) + (m * 60)
        } : -1
      end
      attributes
    end

    def lifecycle_attributes
      array_parameter(:person_ids) if params.key?(:person_ids)
      params.permit(:mode, :boundary_index, :lock_version, :lifecycle_revision, person_ids: []).to_h.symbolize_keys
    end

    def confirm_lifecycle(operation)
      command(operation, @schedule, lifecycle_attributes, success_path: schedule_path(@schedule),
                                                          template: "munawaba/shared/proposal") do
        refresh_proposal(operation, @schedule, lifecycle_attributes)
      end
    end

    def prepare_resume_form
      @resume_people = Person.where(active: true).order(:name).to_a
      ids = params.key?(:person_ids) ? array_parameter(:person_ids).reject(&:blank?) : ScheduleMembership.where(schedule_id: @schedule.id).order(:position).pluck(:person_id)
      maximum = [Defaults::MAXIMUM_SCHEDULE_MEMBERS, @resume_people.length].min
      @resume_ids = (ids + [nil]).first(maximum)
    end
  end
end
