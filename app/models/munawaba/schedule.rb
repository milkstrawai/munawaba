# frozen_string_literal: true

module Munawaba
  class Schedule < ApplicationRecord
    self.table_name = "munawaba_schedules"
    STATES = %w[draft scheduled active pausing paused].freeze
    CADENCES = %w[one_week two_weeks calendar_month].freeze
    TIMING_FIELDS = %w[cadence time_zone anchor_local_date anchor_local_seconds].freeze
    has_many :schedule_memberships, -> {
      order(:position)
    }, class_name: "Munawaba::ScheduleMembership", inverse_of: :schedule
    has_many :people, through: :schedule_memberships
    has_many :shifts, class_name: "Munawaba::Shift"
    has_many :notification_deliveries, class_name: "Munawaba::NotificationDelivery"
    has_many :audit_events, class_name: "Munawaba::AuditEvent"
    encrypts :slack_webhook_url
    self.filter_attributes += [:slack_webhook_url]
    normalizes :name, with: ->(value) { value.strip }
    validates :name, presence: true, length: { maximum: 120 }, uniqueness: { case_sensitive: false }
    validates :state, inclusion: { in: STATES }
    validates :cadence, inclusion: { in: CADENCES }
    validates :time_zone, presence: true, length: { maximum: 100 }
    validates :anchor_local_date, presence: true
    validates :anchor_local_seconds,
              numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 86340 }
    validates :advance_notice_seconds,
              numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: 2592000 }
    validates :coverage_revision, :rotation_revision, :lifecycle_revision, :notification_revision, :lock_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :valid_time_zone
    validate {
      errors.add(:anchor_local_date,
                 "must have a four-digit year (0001–9999)") if anchor_local_date && !(1..9999).cover?(anchor_local_date.year)
    }
    validate :minute_precision
    validate :immutable_timing_after_commitment
    validate :slack_configuration

    def current_shift(at = Time.current)
      shifts.live.current(at).first
    end

    def next_shift(at = Time.current)
      shifts.live.where("starts_at > ?", at.utc).order(:starts_at, :id).first
    end

    def ordered_person_ids
      schedule_memberships.reorder(:position).pluck(:person_id)
    end

    private

    def valid_time_zone
      TZInfo::Timezone.get(time_zone) if time_zone.present?
    rescue TZInfo::InvalidTimezoneIdentifier
      errors.add(:time_zone, "must be an IANA timezone")
    end

    def minute_precision
      errors.add(:anchor_local_seconds,
                 "must have minute precision") if anchor_local_seconds && anchor_local_seconds % 60 != 0
    end

    def immutable_timing_after_commitment
      return unless persisted? && (first_activated_at_in_database.present? || state_in_database == "scheduled")

      errors.add(:base, "Timing can only change on a draft that has never started.") if (changed & TIMING_FIELDS).any?
    end

    def slack_configuration
      if slack_webhook_url.present? != slack_webhook_configured_at.present?
        errors.add(:slack_webhook_url, "configuration timestamp must match the webhook")
      end
      errors.add(:slack_enabled, "requires a webhook") if slack_enabled && slack_webhook_url.blank?
      return if slack_webhook_url.blank? || !will_save_change_to_slack_webhook_url?

      unless Slack::WebhookValidator.valid?(slack_webhook_url)
        errors.add(:slack_webhook_url, "must be an allowed Slack incoming webhook")
      end
      unless ActiveRecord::Encryption.config.has_primary_key? && ActiveRecord::Encryption.config.has_key_derivation_salt?
        errors.add(:slack_webhook_url, "requires host Active Record Encryption keys")
      end
    end
  end
end
