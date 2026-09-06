# frozen_string_literal: true

module Munawaba
  class Shift < ApplicationRecord
    self.table_name = "munawaba_shifts"
    belongs_to :schedule, class_name: "Munawaba::Schedule"
    belongs_to :base_person, class_name: "Munawaba::Person"
    belongs_to :effective_person, class_name: "Munawaba::Person"
    has_many :shift_overrides, class_name: "Munawaba::ShiftOverride"
    has_one :active_override, -> { where(ended_at: nil) }, class_name: "Munawaba::ShiftOverride"
    has_many :notification_deliveries, class_name: "Munawaba::NotificationDelivery"
    validates :starts_at, :ends_at, :generated_at, presence: true
    validates :coverage_revision, :assignment_version, :timing_version,
              numericality: { only_integer: true, greater_than: 0 }
    validates :boundary_index, :rotation_revision, :lock_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :cancellation_reason, inclusion: { in: %w[pause scheduled_run_canceled] }, allow_nil: true
    validate :interval_and_cancellation
    validate { errors.add(:base, "Canceled shifts are terminal") if persisted? && canceled_at_in_database && changed? }
    scope :live, -> { where(canceled_at: nil) }
    scope :current, ->(at = Time.current) { where("starts_at <= ? AND ends_at > ?", at.utc, at.utc) }
    scope :overlapping, ->(from, to) {
      where("tstzrange(starts_at, ends_at, '[)') && tstzrange(?, ?, '[)')", from.utc, to.utc)
    }
    def canceled? = canceled_at.present?

    def self.persist_projection!(schedule:, slots:, now:)
      connection.execute("SET CONSTRAINTS ALL DEFERRED")
      rows = where(id: slots.filter_map { |slot| slot[:id] }).index_by(&:id)
      slots.map do |slot|
        values = slot.slice(:coverage_revision, :boundary_index, :starts_at, :ends_at, :base_person_id, :effective_person_id,
                            :rotation_revision, :assignment_version, :timing_version)
        if slot[:id]
          row = rows.fetch(slot[:id])
          row.update!(values) if values.any? { |key, value| row.public_send(key) != value }
          row
        else
          create!(values.merge(schedule_id: schedule.id, generated_at: now))
        end
      end
    end

    private

    def interval_and_cancellation
      errors.add(:ends_at, "must be after the start") if starts_at && ends_at && ends_at <= starts_at
      errors.add(:cancellation_reason,
                 "must match the cancellation time") unless canceled_at.nil? == cancellation_reason.nil?
    end
  end
end
