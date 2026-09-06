# frozen_string_literal: true

module Munawaba
  module Shifts
    class ProjectionPlan
      MAX_BIGINT = 9_223_372_036_854_775_807
      attr_reader :state, :coverage_revision, :rotation_revision, :first_boundary, :target_boundary,
                  :boundaries, :slots, :canonical

      def initialize(schedule:, operation_kind:, now:, person_ids:, first_boundary:, target_boundary: nil,
                     conflict_check_at: nil, provider: Timing::BoundaryCalculator.method(:timezone))
        @schedule_id = schedule.id
        @operation_kind = operation_kind.to_s
        @first_boundary = Integer(first_boundary)
        @coverage_revision = schedule.coverage_revision + 1
        @rotation_revision = schedule.rotation_revision + (@operation_kind == "resume" ? 1 : 0)
        @conflict_check_at = conflict_check_at && Canonical.time(conflict_check_at)
        @calculator = Timing::BoundaryCalculator.new(schedule, provider: provider)
        @state = @operation_kind == "immediate_activation" || @calculator.boundary(@first_boundary).resolved_at == now ? "active" : "scheduled"
        @target_boundary = target_boundary.nil? ? self.class.target(@calculator, @first_boundary,
                                                                    now + Defaults::SHIFT_GENERATION_HORIZON) : Integer(target_boundary)
        validate!(person_ids)
        @boundaries = (@first_boundary..(@target_boundary + 1)).map { |index| @calculator.boundary(index) }.freeze
        @slots = (@first_boundary..@target_boundary).map do |index|
          left, right = @boundaries[index - @first_boundary, 2]
          immediate = index == @first_boundary && @operation_kind == "immediate_activation"
          base = person_ids[(index - @first_boundary) % person_ids.length]
          { schedule_id: @schedule_id, id: nil, coverage_revision: @coverage_revision, boundary_index: index,
            starts_at: immediate ? @conflict_check_at : left.resolved_at, ends_at: right.resolved_at,
            base_person_id: base, effective_person_id: base, rotation_revision: @rotation_revision,
            assignment_version: 1, timing_version: 1, start_resolution: immediate ? nil : left.resolution,
            start_adjustment_seconds: immediate ? nil : left.adjustment_seconds,
            end_resolution: right.resolution, end_adjustment_seconds: right.adjustment_seconds,
            start_basis: immediate ? "activation_conflict_check" : "canonical" }
        end
        @slots.each { |slot|
          raise ArgumentError, "Invalid projected interval" unless slot[:ends_at] > slot[:starts_at]
        }
        Canonical.deep_freeze(@slots)
        @canonical = [1, @operation_kind, @schedule_id, @state, @coverage_revision, @rotation_revision,
                      @first_boundary, @target_boundary, @operation_kind == "immediate_activation" ? "confirmation_now_subset" : "canonical",
                      @conflict_check_at && Canonical.micros(@conflict_check_at),
                      [schedule.cadence, schedule.time_zone, schedule.anchor_local_date.iso8601, schedule.anchor_local_seconds],
                      @boundaries.map { |b|
                        [b.index, b.nominal_local_date.iso8601, b.nominal_local_seconds, Canonical.micros(b.resolved_at), b.resolution, b.adjustment_seconds, b.utc_offset_seconds]
                      },
                      @slots.map { |s|
                        [s[:boundary_index], Canonical.micros(s[:starts_at]), Canonical.micros(s[:ends_at]), s[:base_person_id], s[:effective_person_id], s[:start_resolution], s[:start_adjustment_seconds], s[:end_resolution], s[:end_adjustment_seconds], s[:rotation_revision], s[:assignment_version], s[:timing_version], s[:start_basis]]
                      }]
        Canonical.deep_freeze(@canonical)
        freeze
      end

      def digest = Canonical.digest(@canonical)

      def persistence_slots(now:)
        return @slots unless @operation_kind == "immediate_activation"
        raise ArgumentError,
              "Immediate activation left its acknowledged slot" unless @conflict_check_at <= now && now < @slots.first[:ends_at]

        Canonical.deep_freeze(@slots.map.with_index { |slot, index| index.zero? ? slot.merge(starts_at: now) : slot })
      end

      def self.target(calculator, first_boundary, cutoff)
        cutoff = [cutoff, calculator.boundary(first_boundary + 1).resolved_at].max
        [first_boundary, calculator.slot_at(cutoff)].max
      end

      private

      def validate!(person_ids)
        valid = %w[immediate_activation future_activation resume].include?(@operation_kind) &&
                @schedule_id.is_a?(Integer) && @schedule_id.between?(1, MAX_BIGINT) &&
                @coverage_revision.between?(1, MAX_BIGINT) && @rotation_revision.between?(0, MAX_BIGINT) &&
                @first_boundary.between?(0,
                                         MAX_BIGINT - 1) && @target_boundary.between?(@first_boundary,
                                                                                      MAX_BIGINT - 1) &&
                person_ids.present? && person_ids.uniq == person_ids && person_ids.all? { |id|
                                                                          id.is_a?(Integer) && id.between?(1,
                                                                                                           MAX_BIGINT)
                                                                        }
        valid &&= @operation_kind == "immediate_activation" ? !@conflict_check_at.nil? : @conflict_check_at.nil?
        valid &&= @first_boundary.zero? if @operation_kind == "future_activation"
        valid &&= @calculator.boundary(@first_boundary).resolved_at <= @conflict_check_at if @operation_kind == "immediate_activation"
        raise ArgumentError, "Invalid projection plan" unless valid
      end
    end
  end
end
