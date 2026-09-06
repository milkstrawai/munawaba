# frozen_string_literal: true

module Munawaba
  module Notifications
    class Deliver
      def self.call(delivery_id, claim_token)
        row = NotificationDelivery.find_by(id: delivery_id, claim_token: claim_token, status: "enqueued")
        return unless row && row.lease_expires_at > Time.current
        unless Munawaba.config.notifications_enabled?
          return Dispatcher.reset(delivery_id, claim_token, Time.current, signal: false)
        end

        check = Validity.call(row)
        unless check.valid?
          reject_claim(delivery_id, claim_token, check)
          return
        end
        payload = Slack::Renderer.call(delivery: row, schedule: check.schedule, shift: check.shift)
        webhook = check.schedule.slack_webhook_url
        deadline = Slack::Client.monotonic + Defaults::SLACK_TOTAL_TIMEOUT.to_f
        authorized = NotificationDelivery.transaction do
          current = NotificationDelivery.where(id: delivery_id, claim_token: claim_token,
                                               status: "enqueued").lock("FOR NO KEY UPDATE").first
          now = Time.current
          next false unless current && current.lease_expires_at > now

          unless Munawaba.config.notifications_enabled?
            current.mark_pending!(at: now)
            next false
          end
          final = Validity.call(current, now: now)
          unless final.valid?
            current.finish!(status: final.status, code: final.code, now: now)
            request_timing_maintenance(current.schedule_id) if final.code == "timing_rules_changed"
            next false
          end
          current.update!(status: "processing", processing_at: now, lease_expires_at: now + Defaults::NOTIFICATION_PROCESSING_LEASE,
                          attempt_count: current.attempt_count + 1, last_attempt_at: now, last_http_status: nil,
                          last_error_code: current.last_error_code == "delivery_outcome_unknown" ? current.last_error_code : nil)
          true
        end
        return unless authorized

        outcome = Slack::Client.call(webhook: webhook, payload: payload, deadline: deadline)
        complete(delivery_id, claim_token, outcome)
      rescue Context::V1::Invalid, ActiveRecord::Encryption::Errors::Base, Slack::WebhookValidator::Invalid
        reject_claim(delivery_id, claim_token, Validity::Result.new(status: :stale, code: "invalid_delivery_context"))
      end

      def self.complete(id, token, outcome)
        NotificationDelivery.transaction do
          row = NotificationDelivery.where(id: id, claim_token: token,
                                           status: "processing").lock("FOR NO KEY UPDATE").first
          unless row
            Munawaba.signal("notification_late_result")
            next
          end
          now = Time.current
          row.last_http_status = outcome.http_status
          if outcome.status == :delivered
            row.finish!(status: :delivered, now: now, http_status: outcome.http_status)
          elsif outcome.status == :failed
            row.last_error_code = "delivery_outcome_unknown" if outcome.unknown
            row.finish!(status: :failed, code: outcome.error_code, now: now, http_status: outcome.http_status)
          else
            row.retry_later!(now: now, code: outcome.error_code, retry_after: outcome.retry_after,
                             unknown: outcome.unknown)
          end
        end
      end

      def self.reject_claim(id, token, result)
        NotificationDelivery.transaction do
          row = NotificationDelivery.where(id: id, claim_token: token,
                                           status: "enqueued").lock("FOR NO KEY UPDATE").first
          if row
            row.finish!(status: result.status, code: result.code)
            request_timing_maintenance(row.schedule_id) if result.code == "timing_rules_changed"
          end
        end
      end

      def self.request_timing_maintenance(schedule_id)
        ActiveRecord.after_all_transactions_commit do
          begin
            MaintenanceJob.perform_later(schedule_id)
          rescue StandardError
            Munawaba.signal("timing_wake_failed")
          end
        end
      end
    end
  end
end
