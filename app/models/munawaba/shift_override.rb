# frozen_string_literal: true

module Munawaba
  class ShiftOverride < ApplicationRecord
    self.table_name = "munawaba_shift_overrides"
    END_REASONS = %w[revoked superseded restored_to_base shift_canceled].freeze
    belongs_to :shift, class_name: "Munawaba::Shift"
    belongs_to :previous_person, class_name: "Munawaba::Person"
    belongs_to :replacement_person, class_name: "Munawaba::Person"
    normalizes :reason, with: ->(value) { value.strip.presence }
    validates :reason, length: { maximum: 1000 }
    validates :end_reason, inclusion: { in: END_REASONS }, allow_nil: true
    validate :valid_transition

    private

    def valid_transition
      errors.add(:replacement_person,
                 "must differ from the previous person") if previous_person_id == replacement_person_id
      errors.add(:replacement_person,
                 "must be active") if new_record? && replacement_person && !replacement_person.active?
      errors.add(:end_reason, "must match the end time") unless ended_at.nil? == end_reason.nil?
      errors.add(:ended_at, "cannot precede creation") if ended_at && created_at && ended_at < created_at
      return unless persisted?

      errors.add(:base, "Ended overrides are terminal") if ended_at_in_database && changed?
      errors.add(:base, "Only an override terminal transition may be updated") if (changed - %w[ended_at end_reason
                                                                                                updated_at]).any?
    end
  end
end
