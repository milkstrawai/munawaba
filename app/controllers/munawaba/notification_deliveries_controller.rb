# frozen_string_literal: true

module Munawaba
  class NotificationDeliveriesController < ApplicationController
    def index
      %i[schedule_id status].each { |key| scalar_parameter(key) }
      scope = NotificationDelivery.all
      scope = scope.where(schedule_id: params[:schedule_id]) if params[:schedule_id].present?
      scope = scope.where(status: params[:status]) if params[:status].present?
      @deliveries = before_cursor(scope, "created_at").order(created_at: :desc,
                                                             id: :desc).includes(:schedule).limit(page_size + 1).to_a
      @more = @deliveries.size > page_size
      @deliveries = @deliveries.first(page_size)
      @schedules = Schedule.order(:name)
    end

    def retry
      result = Notifications::RetryFailed.call(delivery: @delivery, actor: actor,
                                               acknowledge_duplicate: params[:acknowledge_duplicate] == "1")
      if result.success?
        redirect_to notification_deliveries_path(schedule_id: @delivery.schedule_id), status: :see_other,
                                                                                      notice: "Retry queued."
      else
        @errors = Array(result.errors)
        # Authorization covers this delivery only. Keep a failed retry's error
        # page limited to that record instead of loading global delivery history.
        @deliveries = [@delivery.reload]
        @schedules = [@delivery.schedule]
        @more = false
        render :index, status: result.status
      end
    end

    private

    def authorization_target
      @delivery = NotificationDelivery.find(params[:id]) if action_name == "retry"
      [:manage_integrations, @delivery || :notification_deliveries]
    end
  end
end
