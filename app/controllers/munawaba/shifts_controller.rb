# frozen_string_literal: true

module Munawaba
  class ShiftsController < ApplicationController
    def show
      @overrides = ShiftOverride.where(shift_id: @shift.id).order(created_at: :desc)
    end

    private

    def authorization_target
      @shift = Shift.includes(:schedule, :base_person, :effective_person).find(params[:id])
      [:read, @shift]
    end
  end
end
