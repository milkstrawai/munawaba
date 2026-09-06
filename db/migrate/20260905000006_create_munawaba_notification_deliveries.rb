# frozen_string_literal: true

class CreateMunawabaNotificationDeliveries < ActiveRecord::Migration[7.2]
  def up
    create_table :munawaba_notification_deliveries do |t|
      t.bigint :schedule_id, null: false
      t.bigint :shift_id
      t.bigint :retry_of_delivery_id
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.string :event_key, limit: 255, null: false
      t.bigint :coverage_revision
      t.bigint :assignment_version
      t.bigint :timing_version
      t.bigint :rotation_revision
      t.bigint :notification_revision, null: false
      t.jsonb :context, null: false, default: {}
      t.column :due_at, :timestamptz, precision: 6, null: false
      t.column :next_attempt_at, :timestamptz, precision: 6
      t.column :expires_at, :timestamptz, precision: 6, null: false
      t.uuid :claim_token
      t.column :enqueued_at, :timestamptz, precision: 6
      t.column :processing_at, :timestamptz, precision: 6
      t.column :lease_expires_at, :timestamptz, precision: 6
      t.column :last_attempt_at, :timestamptz, precision: 6
      t.integer :attempt_count, null: false, default: 0
      t.integer :last_http_status
      t.string :last_error_code, limit: 64
      t.column :delivered_at, :timestamptz, precision: 6
      t.column :created_at, :timestamptz, precision: 6, null: false
      t.column :updated_at, :timestamptz, precision: 6, null: false
    end
    add_foreign_key :munawaba_notification_deliveries, :munawaba_schedules, column: :schedule_id, on_delete: :restrict
    add_foreign_key :munawaba_notification_deliveries, :munawaba_shifts, column: :shift_id, on_delete: :restrict
    add_foreign_key :munawaba_notification_deliveries, :munawaba_notification_deliveries,
                    column: :retry_of_delivery_id, on_delete: :restrict
    add_index :munawaba_notification_deliveries, :event_key, unique: true, name: "mn_deliveries_event_unique"
    add_index :munawaba_notification_deliveries, :retry_of_delivery_id, unique: true,
                                                                        where: "retry_of_delivery_id IS NOT NULL", name: "mn_deliveries_retry_unique"
    add_index :munawaba_notification_deliveries, [:next_attempt_at, :id], where: "status = 'pending'",
                                                                          name: "mn_deliveries_pending_due"
    add_index :munawaba_notification_deliveries, [:expires_at, :id], where: "status = 'pending'",
                                                                     name: "mn_deliveries_pending_expiry"
    add_index :munawaba_notification_deliveries, [:lease_expires_at, :id],
              where: "status IN ('enqueued','processing')", name: "mn_deliveries_lease_expiry"
    add_index :munawaba_notification_deliveries, [:shift_id, :kind, :assignment_version, :timing_version],
              name: "mn_deliveries_shift_versions"
    add_index :munawaba_notification_deliveries,
              [:schedule_id, :kind, :coverage_revision, :rotation_revision, :timing_version, :notification_revision], name: "mn_deliveries_schedule_versions"
    add_index :munawaba_notification_deliveries, [:schedule_id, :created_at, :id],
              order: { created_at: :desc, id: :desc }, name: "mn_deliveries_schedule_history"
    add_index :munawaba_notification_deliveries, [:created_at, :id], order: { created_at: :desc, id: :desc },
                                                                     name: "mn_deliveries_history"
    add_index :munawaba_notification_deliveries, [:status, :created_at, :id], order: { created_at: :desc, id: :desc },
                                                                              name: "mn_deliveries_status_history"
    add_index :munawaba_notification_deliveries, [:schedule_id, :status, :created_at, :id],
              order: { created_at: :desc, id: :desc }, name: "mn_deliveries_schedule_status_history"
    add_check_constraint :munawaba_notification_deliveries,
                         "kind IN ('advance_reminder','shift_start','assignment_change','next_assignment_change','test') AND status IN ('pending','enqueued','processing','delivered','failed','canceled','stale')", name: "mn_deliveries_enums"
    add_check_constraint :munawaba_notification_deliveries, "event_key = btrim(event_key) AND event_key <> ''",
                         name: "mn_deliveries_event_key"
    add_check_constraint :munawaba_notification_deliveries,
                         "attempt_count >= 0 AND notification_revision >= 0 AND (coverage_revision IS NULL OR coverage_revision > 0) AND (assignment_version IS NULL OR assignment_version > 0) AND (timing_version IS NULL OR timing_version > 0) AND (rotation_revision IS NULL OR rotation_revision >= 0)", name: "mn_deliveries_versions"
    add_check_constraint :munawaba_notification_deliveries, "expires_at > due_at", name: "mn_deliveries_expiration"
    add_check_constraint :munawaba_notification_deliveries,
                         "(next_attempt_at IS NOT NULL) = (status = 'pending') AND (claim_token IS NOT NULL) = (status IN ('enqueued','processing')) AND (lease_expires_at IS NOT NULL) = (status IN ('enqueued','processing')) AND (delivered_at IS NOT NULL) = (status = 'delivered')", name: "mn_deliveries_status_fields"
    add_check_constraint :munawaba_notification_deliveries,
                         "(status <> 'pending' OR (enqueued_at IS NULL AND processing_at IS NULL)) AND (status <> 'enqueued' OR (enqueued_at IS NOT NULL AND processing_at IS NULL)) AND (status <> 'processing' OR (enqueued_at IS NOT NULL AND processing_at IS NOT NULL))", name: "mn_deliveries_claim_times"
    add_check_constraint :munawaba_notification_deliveries,
                         "(last_error_code IS NULL OR last_error_code ~ '^[a-z][a-z0-9_]{0,63}$') AND (status <> 'failed' OR (last_error_code IS NOT NULL AND last_error_code <> '')) AND (last_http_status IS NULL OR last_http_status BETWEEN 100 AND 599)", name: "mn_deliveries_safe_result"
    add_check_constraint :munawaba_notification_deliveries, <<~SQL.squish, name: "mn_deliveries_kind_fields"
      (kind IN ('advance_reminder','shift_start','assignment_change') AND shift_id IS NOT NULL AND coverage_revision IS NOT NULL AND assignment_version IS NOT NULL AND timing_version IS NOT NULL AND rotation_revision IS NULL)
      OR (kind = 'next_assignment_change' AND shift_id IS NULL AND coverage_revision IS NOT NULL AND rotation_revision IS NOT NULL AND timing_version IS NOT NULL AND assignment_version IS NULL)
      OR (kind = 'test' AND shift_id IS NULL AND coverage_revision IS NULL AND assignment_version IS NULL AND timing_version IS NULL AND rotation_revision IS NULL)
    SQL
    add_check_constraint :munawaba_notification_deliveries,
                         "jsonb_typeof(context) = 'object' AND octet_length(context::text) <= 16384", name: "mn_deliveries_context"
  end

  def down
    drop_table :munawaba_notification_deliveries
  end
end
