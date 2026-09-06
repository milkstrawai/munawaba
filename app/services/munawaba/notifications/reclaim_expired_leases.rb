# frozen_string_literal: true

module Munawaba
  module Notifications
    class ReclaimExpiredLeases
      def self.call(now: Time.current)
        NotificationDelivery.transaction do
          NotificationDelivery.where(status: %w[enqueued processing]).where("lease_expires_at <= ?", now)
                              .order(:lease_expires_at, :id).limit(Defaults::NOTIFICATION_BATCH_SIZE)
                              .lock("FOR UPDATE SKIP LOCKED").each do |row|
            was_processing = row.status == "processing"
            row.last_error_code = "delivery_outcome_unknown" if was_processing
            validity = Validity.call(row, now: now)
            if !validity.valid?
              row.finish!(status: validity.status, code: validity.code, now: now)
              Deliver.request_timing_maintenance(row.schedule_id) if validity.code == "timing_rules_changed"
            elsif was_processing
              row.retry_later!(now: now, code: "delivery_outcome_unknown", unknown: true, validity: validity)
            else
              row.mark_pending!(at: now)
            end
          end.size
        end
      end
    end
  end
end
