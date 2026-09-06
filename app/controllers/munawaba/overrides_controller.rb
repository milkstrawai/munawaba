# frozen_string_literal: true

module Munawaba
  class OverridesController < ApplicationController
    def new
      @people = Person.where(active: true).order(:name)
      render :new
    end
    alias_method :edit, :new

    def preview
      proposal(override_operation, @shift, override_attributes)
    end

    def create
      confirm_override(:override)
    end
    alias_method :update, :create

    def revoke
      confirm_override(:revoke)
    end

    def restore
      confirm_override(:restore_to_base)
    end

    private

    def authorization_target
      @shift = Shift.includes(:schedule, :base_person, :effective_person).find(params[:shift_id])
      [:override_shifts, @shift]
    end

    def override_operation
      { "apply" => :override, "revoke" => :revoke, "restore_to_base" => :restore_to_base }.fetch(
        params[:operation].to_s, :override
      )
    end

    def override_attributes
      params.permit(:person_id, :reason, :lock_version).to_h.symbolize_keys
    end

    def confirm_override(operation)
      command(operation, @shift, override_attributes, success_path: shift_path(@shift),
                                                      template: "munawaba/shared/proposal") do
        refresh_proposal(operation, @shift, override_attributes)
      end
    end
  end
end
