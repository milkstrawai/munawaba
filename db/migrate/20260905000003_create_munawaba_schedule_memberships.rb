# frozen_string_literal: true

class CreateMunawabaScheduleMemberships < ActiveRecord::Migration[7.2]
  def up
    create_table :munawaba_schedule_memberships do |t|
      t.bigint :schedule_id, null: false
      t.bigint :person_id, null: false
      t.integer :position, null: false
      t.column :created_at, :timestamptz, precision: 6, null: false
      t.column :updated_at, :timestamptz, precision: 6, null: false
    end
    add_foreign_key :munawaba_schedule_memberships, :munawaba_schedules, column: :schedule_id, on_delete: :restrict
    add_foreign_key :munawaba_schedule_memberships, :munawaba_people, column: :person_id, on_delete: :restrict
    add_index :munawaba_schedule_memberships, [:schedule_id, :person_id], unique: true,
                                                                          name: "mn_memberships_person_unique"
    add_index :munawaba_schedule_memberships, [:schedule_id, :position], unique: true,
                                                                         name: "mn_memberships_position_unique"
    add_index :munawaba_schedule_memberships, [:person_id, :schedule_id], name: "mn_memberships_person_schedule"
    add_check_constraint :munawaba_schedule_memberships, "position >= 0", name: "mn_memberships_position"
  end

  def down
    drop_table :munawaba_schedule_memberships
  end
end
