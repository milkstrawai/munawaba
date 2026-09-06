# frozen_string_literal: true

class CreateMunawabaSchedules < ActiveRecord::Migration[7.2]
  def up
    create_table :munawaba_schedules do |t|
      t.string :name, limit: 120, null: false
      t.string :state, null: false, default: "draft"
      t.string :cadence, null: false
      t.string :time_zone, limit: 100, null: false
      t.date :anchor_local_date, null: false
      t.integer :anchor_local_seconds, null: false
      t.column :first_activated_at, :timestamptz, precision: 6
      t.bigint :coverage_revision, null: false, default: 0
      t.bigint :coverage_start_boundary
      t.column :coverage_starts_at, :timestamptz, precision: 6
      t.bigint :generated_through_boundary
      t.bigint :rotation_revision, null: false, default: 0
      t.bigint :rotation_effective_boundary
      t.column :pause_effective_at, :timestamptz, precision: 6
      t.bigint :lifecycle_revision, null: false, default: 0
      t.bigint :notification_revision, null: false, default: 0
      t.text :slack_webhook_url
      t.boolean :slack_enabled, null: false, default: false
      t.boolean :notify_advance, null: false, default: true
      t.integer :advance_notice_seconds, null: false, default: 86400
      t.boolean :notify_shift_start, null: false, default: true
      t.boolean :notify_assignment_change, null: false, default: true
      t.boolean :notify_next_assignment_change, null: false, default: true
      t.column :slack_webhook_configured_at, :timestamptz, precision: 6
      t.integer :lock_version, null: false, default: 0
      t.column :created_at, :timestamptz, precision: 6, null: false
      t.column :updated_at, :timestamptz, precision: 6, null: false
    end
    add_index :munawaba_schedules, "lower(name)", unique: true, name: "mn_schedules_name_unique"
    add_index :munawaba_schedules, [:coverage_starts_at, :id], where: "state = 'scheduled'",
                                                               name: "mn_schedules_scheduled_due"
    add_index :munawaba_schedules, [:pause_effective_at, :id], where: "state = 'pausing'",
                                                               name: "mn_schedules_pausing_due"
    add_check_constraint :munawaba_schedules,
                         "name = btrim(name) AND name <> '' AND time_zone = btrim(time_zone) AND time_zone <> ''", name: "mn_schedules_names"
    add_check_constraint :munawaba_schedules,
                         "state IN ('draft','scheduled','active','pausing','paused') AND cadence IN ('one_week','two_weeks','calendar_month')", name: "mn_schedules_enums"
    add_check_constraint :munawaba_schedules,
                         "anchor_local_seconds BETWEEN 0 AND 86340 AND anchor_local_seconds % 60 = 0", name: "mn_schedules_anchor_seconds"
    add_check_constraint :munawaba_schedules,
                         "coverage_revision >= 0 AND rotation_revision >= 0 AND lifecycle_revision >= 0 AND notification_revision >= 0 AND lock_version >= 0", name: "mn_schedules_versions"
    add_check_constraint :munawaba_schedules,
                         "(coverage_start_boundary IS NULL OR coverage_start_boundary >= 0) AND (generated_through_boundary IS NULL OR generated_through_boundary >= 0) AND (rotation_effective_boundary IS NULL OR rotation_effective_boundary >= 0)", name: "mn_schedules_boundary_indexes"
    add_check_constraint :munawaba_schedules, "generated_through_boundary >= coverage_start_boundary",
                         name: "mn_schedules_cursor"
    add_check_constraint :munawaba_schedules,
                         "state NOT IN ('active','scheduled') OR rotation_effective_boundary BETWEEN coverage_start_boundary AND generated_through_boundary", name: "mn_schedules_rotation_boundary"
    add_check_constraint :munawaba_schedules, "first_activated_at <= coverage_starts_at",
                         name: "mn_schedules_first_start"
    add_check_constraint :munawaba_schedules, "coverage_revision > 0 OR state = 'draft'",
                         name: "mn_schedules_revision_state"
    add_check_constraint :munawaba_schedules, "advance_notice_seconds BETWEEN 60 AND 2592000",
                         name: "mn_schedules_notice"
    add_check_constraint :munawaba_schedules,
                         "(slack_webhook_url IS NULL) = (slack_webhook_configured_at IS NULL) AND (NOT slack_enabled OR slack_webhook_url IS NOT NULL)", name: "mn_schedules_slack_presence"
    add_check_constraint :munawaba_schedules, <<~SQL.squish, name: "mn_schedules_state_fields"
      (state = 'draft' AND first_activated_at IS NULL AND coverage_start_boundary IS NULL AND coverage_starts_at IS NULL AND generated_through_boundary IS NULL AND rotation_effective_boundary IS NULL AND pause_effective_at IS NULL)
      OR (state = 'scheduled' AND coverage_revision > 0 AND coverage_start_boundary IS NOT NULL AND coverage_starts_at IS NOT NULL AND generated_through_boundary IS NOT NULL AND rotation_effective_boundary IS NOT NULL AND pause_effective_at IS NULL)
      OR (state = 'active' AND coverage_revision > 0 AND first_activated_at IS NOT NULL AND coverage_start_boundary IS NOT NULL AND coverage_starts_at IS NOT NULL AND generated_through_boundary IS NOT NULL AND rotation_effective_boundary IS NOT NULL AND pause_effective_at IS NULL)
      OR (state = 'pausing' AND first_activated_at IS NOT NULL AND coverage_start_boundary IS NOT NULL AND coverage_starts_at IS NOT NULL AND generated_through_boundary IS NOT NULL AND rotation_effective_boundary IS NULL AND pause_effective_at IS NOT NULL AND pause_effective_at > coverage_starts_at)
      OR (state = 'paused' AND first_activated_at IS NOT NULL AND coverage_start_boundary IS NULL AND coverage_starts_at IS NULL AND generated_through_boundary IS NULL AND rotation_effective_boundary IS NULL AND pause_effective_at IS NULL)
    SQL
  end

  def down
    drop_table :munawaba_schedules
  end
end
