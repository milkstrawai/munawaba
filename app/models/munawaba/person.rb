# frozen_string_literal: true

module Munawaba
  class Person < ApplicationRecord
    self.table_name = "munawaba_people"
    has_many :schedule_memberships, class_name: "Munawaba::ScheduleMembership", inverse_of: :person
    has_many :schedules, through: :schedule_memberships
    has_many :effective_shifts, class_name: "Munawaba::Shift", foreign_key: :effective_person_id
    has_many :base_shifts, class_name: "Munawaba::Shift", foreign_key: :base_person_id
    has_many :audit_events, class_name: "Munawaba::AuditEvent"

    normalizes :name, with: ->(value) { value.strip }
    normalizes :email, with: ->(value) { value.strip.downcase }
    normalizes :slack_member_id, with: ->(value) { value.strip.presence }
    validates :name, presence: true, length: { maximum: 120 }
    validates :email, presence: true, length: { maximum: 320 }, uniqueness: { case_sensitive: false }, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :slack_member_id, allow_nil: true, uniqueness: true, format: { with: /\A[A-Z][A-Z0-9]{1,31}\z/ }
    validates :active, inclusion: { in: [true, false] }
    validates :lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate { errors.add(:deactivated_at, "must match active status") unless active == deactivated_at.nil? }
    scope :active, -> { where(active: true) }
  end
end
