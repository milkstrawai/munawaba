# frozen_string_literal: true

class CreateMunawabaAuditEvents < ActiveRecord::Migration[7.2]
  def up
    create_table :munawaba_audit_events do |t|
      t.uuid :operation_id, null: false
      t.string :event_type, limit: 100, null: false
      t.bigint :schedule_id
      t.bigint :person_id
      t.bigint :shift_id
      t.string :actor_type, limit: 100
      t.string :actor_id, limit: 255
      t.string :actor_name, limit: 255
      t.jsonb :metadata, null: false, default: {}
      t.column :occurred_at, :timestamptz, precision: 6, null: false
      t.column :created_at, :timestamptz, precision: 6, null: false
    end
    add_foreign_key :munawaba_audit_events, :munawaba_schedules, column: :schedule_id, on_delete: :restrict
    add_foreign_key :munawaba_audit_events, :munawaba_people, column: :person_id, on_delete: :restrict
    add_foreign_key :munawaba_audit_events, :munawaba_shifts, column: :shift_id, on_delete: :restrict
    add_index :munawaba_audit_events, [:occurred_at, :id], name: "mn_audit_history"
    [:schedule_id, :person_id, :shift_id, :event_type].each do |column|
      add_index :munawaba_audit_events, [column, :occurred_at, :id], order: { occurred_at: :desc, id: :desc },
                                                                     name: "mn_audit_#{column}_history"
    end
    add_index :munawaba_audit_events, [:actor_type, :actor_id, :occurred_at, :id],
              order: { occurred_at: :desc, id: :desc }, name: "mn_audit_actor_history"
    add_index :munawaba_audit_events, :operation_id, name: "mn_audit_operation"
    add_check_constraint :munawaba_audit_events,
                         "jsonb_typeof(metadata) = 'object' AND octet_length(metadata::text) <= 131072", name: "mn_audit_metadata"
  end

  def down
    drop_table :munawaba_audit_events
  end
end
