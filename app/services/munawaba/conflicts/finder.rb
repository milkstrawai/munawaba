# frozen_string_literal: true

module Munawaba
  module Conflicts
    class Finder
      # One bound statement provides one snapshot for both conflict branches.
      SQL = <<~SQL.freeze
        WITH proposed_slots AS (
          SELECT * FROM jsonb_to_recordset($1::jsonb) AS proposed(
            target_schedule_id bigint, target_shift_id bigint, coverage_revision bigint,
            boundary_index bigint, effective_person_id bigint, starts_at timestamptz, ends_at timestamptz
          )
        ), pairs AS (
          SELECT p.target_schedule_id AS a_schedule, p.target_shift_id AS a_shift,
            p.coverage_revision AS a_revision, p.boundary_index AS a_boundary,
            e.schedule_id AS b_schedule, e.id AS b_shift, e.coverage_revision AS b_revision,
            e.boundary_index AS b_boundary, p.effective_person_id,
            greatest(p.starts_at, e.starts_at) AS overlap_start, least(p.ends_at,e.ends_at) AS overlap_end
          FROM proposed_slots p JOIN munawaba_shifts e
            ON e.effective_person_id = p.effective_person_id AND e.schedule_id <> p.target_schedule_id
            AND e.canceled_at IS NULL AND tstzrange(e.starts_at,e.ends_at,'[)') && tstzrange(p.starts_at,p.ends_at,'[)')
          WHERE NOT EXISTS (SELECT 1 FROM proposed_slots r WHERE r.target_shift_id = e.id)
          UNION ALL
          SELECT l.target_schedule_id, l.target_shift_id, l.coverage_revision, l.boundary_index,
            r.target_schedule_id, r.target_shift_id, r.coverage_revision, r.boundary_index, l.effective_person_id,
            greatest(l.starts_at,r.starts_at), least(l.ends_at,r.ends_at)
          FROM proposed_slots l JOIN proposed_slots r ON l.effective_person_id = r.effective_person_id
            AND l.target_schedule_id <> r.target_schedule_id
            AND (l.target_schedule_id,l.coverage_revision,l.boundary_index) < (r.target_schedule_id,r.coverage_revision,r.boundary_index)
            AND tstzrange(l.starts_at,l.ends_at,'[)') && tstzrange(r.starts_at,r.ends_at,'[)')
        ), oriented AS (
          SELECT CASE WHEN (a_schedule,a_revision,a_boundary) < (b_schedule,b_revision,b_boundary)
            THEN ARRAY[a_schedule,a_shift,a_revision,a_boundary,b_schedule,b_shift,b_revision,b_boundary,effective_person_id,
              (extract(epoch FROM overlap_start)*1000000)::bigint,(extract(epoch FROM overlap_end)*1000000)::bigint]
            ELSE ARRAY[b_schedule,b_shift,b_revision,b_boundary,a_schedule,a_shift,a_revision,a_boundary,effective_person_id,
              (extract(epoch FROM overlap_start)*1000000)::bigint,(extract(epoch FROM overlap_end)*1000000)::bigint]
            END AS fingerprint FROM pairs
        ) SELECT array_to_json(fingerprint)::text AS fingerprint FROM oriented ORDER BY fingerprint;
      SQL

      def self.call(slots:)
        return [] if slots.empty?

        vector = slots.map do |slot|
          { target_schedule_id: slot.fetch(:schedule_id), target_shift_id: slot[:id],
            coverage_revision: slot.fetch(:coverage_revision), boundary_index: slot.fetch(:boundary_index),
            effective_person_id: slot.fetch(:effective_person_id), starts_at: Canonical.instant(slot.fetch(:starts_at)), ends_at: Canonical.instant(slot.fetch(:ends_at)) }
        end
        bind = ActiveRecord::Relation::QueryAttribute.new("proposed_slots", JSON.generate(vector), ActiveRecord::Type::String.new)
        rows = Shift.connection.exec_query(SQL, "Munawaba conflicts", [bind])
        rows.map { |row| JSON.parse(row.fetch("fingerprint")) }.uniq.sort_by { |entry|
          entry.map { |value|
            value.nil? ? -1 : value
          }
        }.freeze
      end
    end
  end
end
