# frozen_string_literal: true

module Munawaba
  class ThemesController < ApplicationController
    def update
      return head :unprocessable_entity unless %w[dark light].include?(params[:theme])

      cookies.permanent[:munawaba_theme] =
        { value: params[:theme], same_site: :lax, httponly: true, secure: request.ssl? }
      redirect_back fallback_location: root_path, allow_other_host: false, status: :see_other
    end

    private

    def authorization_target
      [:read, :theme]
    end
  end
end
