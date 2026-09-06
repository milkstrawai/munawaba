# frozen_string_literal: true

module Munawaba
  class PeopleController < ApplicationController
    def index
      @people = Person.order(:name, :id)
      @people = @people.where(active: params[:state] == "active") if %w[active inactive].include?(params[:state])
      @people = @people.where("name ILIKE :q OR email ILIKE :q",
                              q: "%#{Person.sanitize_sql_like(params[:q].to_s)}%") if params[:q].present?
      @people = after_name_cursor(@people).limit(page_size + 1).to_a
      @more = @people.size > page_size
      @people = @people.first(page_size)
      @membership_counts = ScheduleMembership.where(person_id: @people.map(&:id)).group(:person_id).count
    end

    def show
      @memberships = ScheduleMembership.where(person_id: @person.id).includes(:schedule).order(:schedule_id)
      @shifts = Shift.where(effective_person_id: @person.id, canceled_at: nil).where("ends_at > ?", Time.current)
                     .includes(:schedule, :effective_person).order(:starts_at).limit(100)
    end

    def new
      @person = Person.new
    end

    def create
      @person = Person.new(person_attributes)
      command(:create_person, @person, person_attributes, success_path: ->(record) {
        person_path(record)
      }, template: "new") do |result|
        @person = result.record if result.record.is_a?(Person)
      end
    end

    def edit; end

    def update
      command(:update_person, @person, person_attributes, success_path: person_path(@person),
                                                          template: "edit") do |_result|
        @person.assign_attributes(person_attributes.except(:lock_version))
      end
    end

    def deactivation
      proposal(:deactivate, @person)
    end

    def deactivate
      command(:deactivate, @person, {}, success_path: person_path(@person),
                                        template: "munawaba/shared/proposal") do
        refresh_proposal(:deactivate, @person, {})
      end
    end

    def reactivate
      command(:reactivate, @person, { lock_version: params[:lock_version] }, success_path: person_path(@person),
                                                                             template: "show") {
        show
      }
    end

    private

    def authorization_target
      @person = Person.find(params[:id]) if params[:id]
      [(%w[index show].include?(action_name) ? :read : :manage_people), @person || Person]
    end

    def person_attributes
      record_parameters(:person).permit(:name, :email, :slack_member_id, :lock_version).to_h.symbolize_keys
    end
  end
end
