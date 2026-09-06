# frozen_string_literal: true

module Munawaba
  class ScheduleMembership < ApplicationRecord
    self.table_name = "munawaba_schedule_memberships"
    belongs_to :schedule, class_name: "Munawaba::Schedule", inverse_of: :schedule_memberships
    belongs_to :person, class_name: "Munawaba::Person", inverse_of: :schedule_memberships
    validates :person_id, uniqueness: { scope: :schedule_id }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                         uniqueness: { scope: :schedule_id }
    validate { errors.add(:person, "must be active") if new_record? && person && !person.active? }
  end
end
