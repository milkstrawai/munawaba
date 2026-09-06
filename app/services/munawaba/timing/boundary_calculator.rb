# frozen_string_literal: true

require "tzinfo"

module Munawaba
  module Timing
    # Resolve each handoff from the original local rule so short months and DST
    # adjustments do not shift later handoffs.
    class BoundaryCalculator
      Boundary = Struct.new(:index, :nominal_local_date, :nominal_local_seconds,
                            :resolved_at, :resolution, :adjustment_seconds, :utc_offset_seconds, keyword_init: true)

      def self.timezone(iana) = TZInfo::Timezone.get(iana)

      def initialize(schedule, provider: Timing::BoundaryCalculator.method(:timezone))
        @schedule = schedule
        @zone = provider.call(schedule.time_zone)
      end

      def boundary(index)
        raise ArgumentError, "Boundary index must be nonnegative" unless index.is_a?(Integer) && index >= 0

        anchor = @schedule.anchor_local_date
        date = case @schedule.cadence
               when "one_week" then anchor + (7 * index)
               when "two_weeks" then anchor + (14 * index)
               when "calendar_month" then anchor >> index
               else raise ArgumentError, "Unknown cadence"
               end
        seconds = @schedule.anchor_local_seconds
        local = Time.utc(date.year, date.month, date.day) + seconds
        periods = @zone.periods_for_local(local)
        adjustment = 0
        if periods.any?
          candidates = periods.map { |period| [local - period.utc_total_offset, period.utc_total_offset] }
          resolved, offset = candidates.min_by(&:first)
          resolution = periods.length > 1 ? "ambiguous_earlier" : "exact"
        else
          # A transition's local gap is [UTC + old offset, UTC + new offset).
          transition = @zone.transitions_up_to(local + (3 * 86_400), local - (3 * 86_400)).find do |item|
            old_offset = item.previous_offset.utc_total_offset
            new_offset = item.offset.utc_total_offset
            instant = item.at.to_time.utc
            new_offset > old_offset && local >= instant + old_offset && local < instant + new_offset
          end
          raise ArgumentError, "Timezone provider did not resolve the local gap" unless transition

          offset = transition.offset.utc_total_offset
          adjustment = offset - transition.previous_offset.utc_total_offset
          resolved = local + adjustment - offset
          resolution = "gap_forward"
        end
        Boundary.new(index: index, nominal_local_date: date, nominal_local_seconds: seconds,
                     resolved_at: resolved.utc.freeze, resolution: resolution.freeze,
                     adjustment_seconds: adjustment, utc_offset_seconds: offset).freeze
      end
      alias call boundary

      def slot_at(instant)
        instant = instant.utc
        raise ArgumentError, "Instant precedes the nominal anchor" if instant < boundary(0).resolved_at

        date = instant.to_date
        anchor = @schedule.anchor_local_date
        index = case @schedule.cadence
                when "one_week" then ((date - anchor).to_i / 7)
                when "two_weeks" then ((date - anchor).to_i / 14)
                when "calendar_month" then ((date.year - anchor.year) * 12) + date.month - anchor.month
                end
        index = [index, 0].max
        index -= 1 while index.positive? && boundary(index).resolved_at > instant
        index += 1 while boundary(index + 1).resolved_at <= instant
        raise ArgumentError,
              "Non-monotonic canonical boundaries" unless boundary(index).resolved_at < boundary(index + 1).resolved_at

        index
      end

      def selectable_boundaries(now:, limit: Munawaba.config.calendar_future_limit)
        first = now < boundary(0).resolved_at ? 0 : slot_at(now)
        first += 1 if boundary(first).resolved_at < now
        last_at = now + limit
        values = []
        while (item = boundary(first)).resolved_at <= last_at
          values << item
          first += 1
        end
        values.freeze
      end
    end
  end
end
