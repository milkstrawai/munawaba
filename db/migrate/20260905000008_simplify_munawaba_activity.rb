# frozen_string_literal: true

class SimplifyMunawabaActivity < ActiveRecord::Migration[7.2]
  def up
    execute "DROP TRIGGER IF EXISTS munawaba_audit_append_only ON munawaba_audit_events"
    execute "DROP FUNCTION IF EXISTS munawaba_reject_audit_mutation()"
    %w[mn_audit_catalog mn_audit_actor mn_audit_envelope].each do |name|
      remove_check_constraint :munawaba_audit_events, name: name, if_exists: true
    end
  end

  def down
    # Existing activity may now contain custom events and optional actors. Do not
    # reinstate legacy restrictions that could reject or lock those records.
  end
end
