# frozen_string_literal: true

class CreateMunawabaPeople < ActiveRecord::Migration[7.2]
  def up
    unless connection.adapter_name == "PostgreSQL" && connection.database_version >= 150000
      raise ActiveRecord::MigrationError, "Munawaba requires PostgreSQL 15 or later"
    end

    create_table :munawaba_people do |t|
      t.string :name, limit: 120, null: false
      t.string :email, limit: 320, null: false
      t.string :slack_member_id, limit: 32
      t.boolean :active, null: false, default: true
      t.column :deactivated_at, :timestamptz, precision: 6
      t.integer :lock_version, null: false, default: 0
      t.column :created_at, :timestamptz, precision: 6, null: false
      t.column :updated_at, :timestamptz, precision: 6, null: false
    end
    add_index :munawaba_people, "lower(email)", unique: true, name: "mn_people_email_unique"
    add_index :munawaba_people, :slack_member_id, unique: true, where: "slack_member_id IS NOT NULL",
                                                  name: "mn_people_slack_unique"
    add_check_constraint :munawaba_people,
                         "name = btrim(name) AND name <> '' AND email = lower(btrim(email)) AND email <> ''", name: "mn_people_identity"
    add_check_constraint :munawaba_people, "slack_member_id IS NULL OR slack_member_id ~ '^[A-Z][A-Z0-9]{1,31}$'",
                         name: "mn_people_slack_format"
    add_check_constraint :munawaba_people, "active = (deactivated_at IS NULL)", name: "mn_people_active"
    add_check_constraint :munawaba_people, "lock_version >= 0", name: "mn_people_lock_version"
  end

  def down
    drop_table :munawaba_people
  end
end
