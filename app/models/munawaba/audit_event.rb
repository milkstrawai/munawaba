# frozen_string_literal: true

module Munawaba
  class AuditEvent < ApplicationRecord
    self.table_name = "munawaba_audit_events"
    belongs_to :schedule, class_name: "Munawaba::Schedule", optional: true
    belongs_to :person, class_name: "Munawaba::Person", optional: true
    belongs_to :shift, class_name: "Munawaba::Shift", optional: true
    validates :event_type, presence: true, length: { maximum: 100 }
    validate do
      unless metadata.is_a?(Hash) && metadata.to_json.bytesize <= 131072
        errors.add(:metadata, "must be an object no larger than 128 KiB")
      end
    end
  end
end
