# frozen_string_literal: true

module Munawaba
  class NotificationDelivery < ApplicationRecord
    self.table_name = "munawaba_notification_deliveries"
    KINDS = %w[advance_reminder shift_start assignment_change next_assignment_change test].freeze
    STATUSES = %w[pending enqueued processing delivered failed canceled stale].freeze
    TERMINAL_STATUSES = %w[delivered failed canceled stale].freeze
    CLEAR_CLAIM = { claim_token: nil, lease_expires_at: nil, enqueued_at: nil, processing_at: nil }.freeze
    belongs_to :schedule, class_name: "Munawaba::Schedule"
    belongs_to :shift, class_name: "Munawaba::Shift", optional: true
    belongs_to :retry_of_delivery, class_name: "Munawaba::NotificationDelivery", optional: true
    has_one :retry_delivery, class_name: "Munawaba::NotificationDelivery", foreign_key: :retry_of_delivery_id
    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }
    validates :event_key, presence: true, length: { maximum: 255 }, uniqueness: true
    validates :due_at, :expires_at, presence: true
    validates :notification_revision, :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :valid_context
    validate {
      errors.add(:base,
                 "Terminal deliveries cannot be reopened") if persisted? && TERMINAL_STATUSES.include?(status_in_database) && changed?
    }
    scope :unsent, -> { where(status: %w[pending enqueued]) }
    scope :pending, -> { where(status: "pending") }
    scope :recent, -> { order(created_at: :desc, id: :desc) }
    STATUSES.each { |value| define_method("#{value}?") { status == value } }

    def mark_pending!(at:, error_code: last_error_code)
      update_columns(**CLEAR_CLAIM, status: "pending", next_attempt_at: at, last_error_code: error_code,
                                    updated_at: Time.current)
    end

    def finish!(status:, code: nil, now: Time.current, http_status: nil)
      unknown = last_error_code == "delivery_outcome_unknown"
      error = status.to_s == "delivered" ? nil : (unknown ? "delivery_outcome_unknown" : code)
      update_columns(**CLEAR_CLAIM, status: status.to_s, next_attempt_at: nil, updated_at: now,
                                    last_error_code: error, last_http_status: http_status || last_http_status,
                                    delivered_at: status.to_s == "delivered" ? now : nil)
    end

    def retry_later!(now:, code:, retry_after: nil, unknown: false, validity: nil)
      sticky = unknown || last_error_code == "delivery_outcome_unknown"
      self.last_error_code = sticky ? "delivery_outcome_unknown" : code
      validity ||= Notifications::Validity.call(self, now: now)
      unless validity.valid?
        finish!(status: validity.status, code: validity.code, now: now)
        return
      end
      if attempt_count >= Defaults::NOTIFICATION_MAX_ATTEMPTS
        finish!(status: :failed, code: "retry_exhausted", now: now)
        return
      end
      window = [Defaults::NOTIFICATION_BACKOFF_CAP.to_f,
                Defaults::NOTIFICATION_BACKOFF_BASE.to_f * (2**[attempt_count - 1, 0].max)].min
      delay = 1 + (SecureRandom.random_number * [window - 1, 0].max)
      delay += retry_after.to_f if retry_after
      at = now + delay
      if at >= expires_at
        finish!(status: :stale, code: "expired_before_retry", now: now)
      else
        update_columns(last_http_status: last_http_status)
        mark_pending!(at: at, error_code: last_error_code)
      end
    end

    private

    def valid_context
      Notifications::Context::V1.validate!(kind: kind, context: context)
    rescue ArgumentError, Munawaba::Error => error
      errors.add(:context, error.message)
    end
  end
end
