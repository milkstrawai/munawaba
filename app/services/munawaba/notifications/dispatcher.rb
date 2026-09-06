# frozen_string_literal: true

module Munawaba
  module Notifications
    class Dispatcher
      def self.call(now: Time.current)
        return 0 unless Munawaba.config.notifications_enabled?

        limit = Defaults::NOTIFICATION_BATCH_SIZE
        NotificationDelivery.transaction do
          NotificationDelivery.where(status: "pending").where("expires_at <= ?", now)
                              .order(:expires_at, :id).limit(limit).lock("FOR UPDATE SKIP LOCKED").each do |delivery|
            delivery.finish!(status: :stale, code: "expired", now: now)
          end
        end
        claimed = NotificationDelivery.transaction do
          next [] unless Munawaba.config.notifications_enabled?

          NotificationDelivery.where(status: "pending").where("next_attempt_at <= ?", now)
                              .order(:next_attempt_at, :id).limit(limit).lock("FOR UPDATE SKIP LOCKED").map do |delivery|
            token = SecureRandom.uuid
            delivery.update!(status: "enqueued", next_attempt_at: nil, claim_token: token,
                             enqueued_at: now, processing_at: nil, lease_expires_at: now + Defaults::NOTIFICATION_ENQUEUE_LEASE)
            [delivery.id, token]
          end
        end
        claimed.each do |id, token|
          begin
            job = DeliverNotificationJob.perform_later(id, token)
            reset(id, token, now) unless job && job.successfully_enqueued?
          rescue StandardError
            reset(id, token, now)
          end
        end
        claimed.size
      end

      def self.reset(id, token, now, signal: true)
        NotificationDelivery.transaction do
          row = NotificationDelivery.where(id: id, claim_token: token,
                                           status: "enqueued").lock("FOR NO KEY UPDATE").first
          row.mark_pending!(at: now) if row
        end
        Munawaba.signal("notification_enqueue_failed") if signal
      rescue ActiveRecord::ActiveRecordError
        Munawaba.signal("notification_enqueue_reset_failed")
      end
    end
  end
end
