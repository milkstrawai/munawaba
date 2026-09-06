# frozen_string_literal: true

module Munawaba
  module Audit
    # Metadata is stored without filtering; omit secrets and request/model snapshots.
    class Recorder
      def self.record!(event_type:, metadata: {}, actor: nil, operation_id: SecureRandom.uuid,
                       occurred_at: Time.current, schedule: nil, person: nil, shift: nil, shift_id: nil)
        snapshot = actor.to_h.symbolize_keys.slice(:type, :id, :name).transform_values { |value| value&.to_s.presence }
        AuditEvent.create!(event_type: event_type, operation_id: operation_id, occurred_at: occurred_at,
                           schedule: schedule, person: person, shift_id: shift&.id || shift_id,
                           actor_type: snapshot[:type], actor_id: snapshot[:id], actor_name: snapshot[:name],
                           metadata: metadata.as_json)
      end
    end
  end
end
