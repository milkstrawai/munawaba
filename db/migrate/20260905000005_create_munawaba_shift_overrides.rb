# frozen_string_literal: true

class CreateMunawabaShiftOverrides < ActiveRecord::Migration[7.2]
  def up
    create_table :munawaba_shift_overrides do |t|
      t.bigint :shift_id, null: false
      t.bigint :previous_person_id, null: false
      t.bigint :replacement_person_id, null: false
      t.text :reason
      t.column :ended_at, :timestamptz, precision: 6
      t.string :end_reason
      t.column :created_at, :timestamptz, precision: 6, null: false
      t.column :updated_at, :timestamptz, precision: 6, null: false
    end
    add_foreign_key :munawaba_shift_overrides, :munawaba_shifts, column: :shift_id, on_delete: :restrict
    add_foreign_key :munawaba_shift_overrides, :munawaba_people, column: :previous_person_id, on_delete: :restrict
    add_foreign_key :munawaba_shift_overrides, :munawaba_people, column: :replacement_person_id, on_delete: :restrict
    add_index :munawaba_shift_overrides, :shift_id, unique: true, where: "ended_at IS NULL",
                                                    name: "mn_overrides_live_unique"
    add_index :munawaba_shift_overrides, [:replacement_person_id, :shift_id], where: "ended_at IS NULL",
                                                                              name: "mn_overrides_replacement_live"
    add_check_constraint :munawaba_shift_overrides, "previous_person_id <> replacement_person_id",
                         name: "mn_overrides_people"
    add_check_constraint :munawaba_shift_overrides,
                         "reason IS NULL OR (reason = btrim(reason) AND reason <> '' AND char_length(reason) <= 1000)", name: "mn_overrides_reason"
    add_check_constraint :munawaba_shift_overrides,
                         "(ended_at IS NULL AND end_reason IS NULL) OR (ended_at IS NOT NULL AND end_reason IS NOT NULL AND ended_at >= created_at AND end_reason IN ('revoked','superseded','restored_to_base','shift_canceled'))", name: "mn_overrides_end"
  end

  def down
    drop_table :munawaba_shift_overrides
  end
end
