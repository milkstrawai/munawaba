# frozen_string_literal: true

module Munawaba
  class RotationsController < ApplicationController
    def edit
      @person_ids = computed_roster(@schedule,
                                    ScheduleMembership.where(schedule_id: @schedule.id).order(:position)).map { |membership|
        membership.person_id.to_s
      }
      prepare_people
    end

    def preview
      @person_ids = array_parameter(:person_ids).map(&:to_s).reject(&:blank?)
      move = params[:move].to_s.split(":", 2)
      index = @person_ids.index(move[1])
      if index
        case move[0]
        when "up" then @person_ids[index - 1], @person_ids[index] = @person_ids[index],
@person_ids[index - 1] if index.positive?
        when "down" then @person_ids[index + 1], @person_ids[index] = @person_ids[index],
@person_ids[index + 1] if index < @person_ids.length - 1
        when "next" then @person_ids.unshift(@person_ids.delete_at(index))
        when "remove" then @person_ids.delete_at(index)
        end
      end
      @person_ids << params[:add_person_id].to_s if params[:add_person_id].present? && !@person_ids.include?(params[:add_person_id].to_s)
      prepare_people
      result = Commands.preview(operation: :rotation, subject: @schedule, attributes: rotation_attributes, actor: actor)
      @preview = result.preview
      @errors = Array(result.errors)
      @operation, @subject, @attributes = :rotation, @schedule, rotation_attributes
      render :edit, status: @errors.present? ? :unprocessable_entity : :ok
    end

    def update
      @person_ids = array_parameter(:person_ids).map(&:to_s).reject(&:blank?)
      prepare_people
      command(:rotation, @schedule, rotation_attributes, success_path: schedule_path(@schedule),
                                                         template: "edit") do
        refresh_proposal(:rotation, @schedule, rotation_attributes)
      end
    end

    private

    def authorization_target
      @schedule = Schedule.find(params[:schedule_id])
      [:manage_rotations, @schedule]
    end

    def prepare_people
      @people_by_id = Person.where(id: @person_ids).index_by { |person| person.id.to_s }
      @available_people = Person.where(active: true).where.not(id: @person_ids).order(:name)
    end

    def rotation_attributes
      { person_ids: @person_ids, lock_version: params[:lock_version] || @schedule.lock_version }
    end
  end
end
