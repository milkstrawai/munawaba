# frozen_string_literal: true

module Munawaba
  class SlackIntegrationsController < ApplicationController
    def edit; end

    def update
      finish Integrations.call(operation: :update, schedule: @schedule, attributes: integration_attributes, actor: actor)
    end

    def remove
      finish Integrations.call(operation: :remove, schedule: @schedule, actor: actor, attributes: { lock_version: params[:lock_version] })
    end

    def test
      finish Integrations.call(operation: :test, schedule: @schedule, actor: actor, attributes: { lock_version: params[:lock_version] })
    end

    private

    def authorization_target
      @schedule = Schedule.find(params[:schedule_id])
      [:manage_integrations, @schedule]
    end

    def integration_attributes
      record_parameters(:integration).permit(:slack_webhook_url, :slack_enabled, :notify_advance,
                                             :advance_notice_seconds, :notify_shift_start, :notify_assignment_change,
                                             :notify_next_assignment_change, :lock_version).to_h.symbolize_keys
    end

    def finish(result)
      if result.success?
        redirect_to edit_schedule_slack_integration_path(@schedule), status: :see_other, notice: "Slack settings saved."
      else
        @errors = Array(result.errors)
        @stale = result.status.to_i == 409
        @schedule.reload
        if action_name == "update"
          @schedule.assign_attributes(integration_attributes.except(:slack_webhook_url, :lock_version))
        end
        render :edit, status: result.status
      end
    end
  end
end
