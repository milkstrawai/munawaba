# frozen_string_literal: true

class CreateMunawabaShifts < ActiveRecord::Migration[7.2]
  def up
    begin
      execute "CREATE EXTENSION IF NOT EXISTS btree_gist"
    rescue ActiveRecord::StatementInvalid => error
      raise ActiveRecord::MigrationError,
            "Munawaba requires btree_gist. Ask the database owner to CREATE EXTENSION btree_gist before installing. (#{error.cause.class})"
    end
    create_table :munawaba_shifts do |t|
      t.bigint :schedule_id, null: false
      t.bigint :coverage_revision, null: false
      t.bigint :boundary_index, null: false
      t.column :starts_at, :timestamptz, precision: 6, null: false
      t.column :ends_at, :timestamptz, precision: 6, null: false
      t.bigint :base_person_id, null: false
      t.bigint :effective_person_id, null: false
      t.bigint :rotation_revision, null: false, default: 0
      t.bigint :assignment_version, null: false, default: 1
      t.bigint :timing_version, null: false, default: 1
      t.column :canceled_at, :timestamptz, precision: 6
      t.string :cancellation_reason
      t.column :generated_at, :timestamptz, precision: 6, null: false
      t.integer :lock_version, null: false, default: 0
      t.column :created_at, :timestamptz, precision: 6, null: false
      t.column :updated_at, :timestamptz, precision: 6, null: false
    end
    add_foreign_key :munawaba_shifts, :munawaba_schedules, column: :schedule_id, on_delete: :restrict
    add_foreign_key :munawaba_shifts, :munawaba_people, column: :base_person_id, on_delete: :restrict
    add_foreign_key :munawaba_shifts, :munawaba_people, column: :effective_person_id, on_delete: :restrict
    add_index :munawaba_shifts, [:schedule_id, :coverage_revision, :boundary_index], unique: true,
                                                                                     name: "mn_shifts_slot_unique"
    add_index :munawaba_shifts, [:schedule_id, :boundary_index], unique: true, where: "canceled_at IS NULL",
                                                                 name: "mn_shifts_live_slot_unique"
    add_index :munawaba_shifts, [:schedule_id, :canceled_at, :starts_at], name: "mn_shifts_schedule_starts"
    add_index :munawaba_shifts, [:effective_person_id, :starts_at, :ends_at], name: "mn_shifts_person_starts_ends"
    execute "CREATE INDEX mn_shifts_person_overlap ON munawaba_shifts USING gist (effective_person_id, tstzrange(starts_at, ends_at, '[)')) WHERE canceled_at IS NULL"
    execute "CREATE INDEX mn_shifts_calendar_overlap ON munawaba_shifts USING gist (tstzrange(starts_at, ends_at, '[)')) WHERE canceled_at IS NULL"
    execute "ALTER TABLE munawaba_shifts ADD CONSTRAINT mn_shifts_no_live_overlap EXCLUDE USING gist (schedule_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&) WHERE (canceled_at IS NULL) DEFERRABLE INITIALLY IMMEDIATE"
    add_check_constraint :munawaba_shifts, "ends_at > starts_at", name: "mn_shifts_interval"
    add_check_constraint :munawaba_shifts,
                         "coverage_revision > 0 AND boundary_index >= 0 AND rotation_revision >= 0 AND assignment_version > 0 AND timing_version > 0 AND lock_version >= 0", name: "mn_shifts_versions"
    add_check_constraint :munawaba_shifts,
                         "(canceled_at IS NULL AND cancellation_reason IS NULL) OR (canceled_at IS NOT NULL AND cancellation_reason IS NOT NULL AND cancellation_reason IN ('pause','scheduled_run_canceled'))", name: "mn_shifts_cancellation"
  end

  def down
    drop_table :munawaba_shifts
  end
end
