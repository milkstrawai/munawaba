# frozen_string_literal: true

module Munawaba
  module ApplicationHelper
    CADENCES = { "one_week" => "One week", "two_weeks" => "Two weeks", "calendar_month" => "One calendar month" }.freeze

    def page_title(title, subtitle = nil)
      content_for(:title, title)
      content_tag(:div, class: "mn-heading") do
        safe_join([content_tag(:h1, title), (content_tag(:p, subtitle, class: "mn-muted") if subtitle)].compact)
      end
    end

    def state_badge(value)
      content_tag(:span, value.to_s.humanize, class: "mn-badge mn-badge-#{value.to_s.parameterize}")
    end

    def effective_schedule_state(schedule)
      @mn_display_now ||= Time.current
      if schedule.state == "scheduled" && schedule.coverage_starts_at && schedule.coverage_starts_at <= @mn_display_now
        "active"
      elsif schedule.state == "pausing" && schedule.pause_effective_at && schedule.pause_effective_at <= @mn_display_now
        "paused"
      else
        schedule.state
      end
    end

    def lifecycle_maintenance_warning(schedule)
      case [schedule.state, effective_schedule_state(schedule)]
      when ["scheduled", "active"]
        "Coverage has started. Waiting for the next maintenance run."
      when ["pausing", "paused"]
        "Coverage has paused. Waiting for the next maintenance run before you can resume."
      end
    end

    def shift_dst_adjustments(shift)
      @mn_boundary_calculators ||= {}
      @mn_boundary_metadata ||= {}
      calculator = (@mn_boundary_calculators[shift.schedule_id] ||= Timing::BoundaryCalculator.new(shift.schedule))
      [["Start", shift.boundary_index, shift.starts_at],
       ["End", shift.boundary_index + 1, shift.ends_at]].filter_map do |edge, index, persisted_at|
        boundary = (@mn_boundary_metadata[[shift.schedule_id, index]] ||= calculator.boundary(index))
        # Started shifts keep their saved times after timezone rules change.
        # Describe a DST adjustment only when it matches the saved boundary.
        next if boundary.resolution == "exact" || boundary.resolved_at != persisted_at

        boundary_adjustment_text(boundary, edge: edge, zone: shift.schedule.time_zone)
      end
    end

    def boundary_adjustment_text(boundary, edge:, zone:)
      nominal_time = format("%02d:%02d", boundary.nominal_local_seconds / 3600,
                            boundary.nominal_local_seconds % 3600 / 60)
      offset = boundary.utc_offset_seconds
      offset_text = format("UTC%s%02d:%02d", offset.negative? ? "-" : "+", offset.abs / 3600, offset.abs % 3600 / 60)
      offset_text += format(":%02d", offset.abs % 60) unless (offset % 60).zero?
      adjustment = boundary.adjustment_seconds
      duration = (adjustment % 60).zero? ? pluralize(adjustment / 60, "minute") : pluralize(adjustment, "second")
      resolution = boundary.resolution == "ambiguous_earlier" ? "earlier occurrence" : "moved forward"
      "DST adjustment · #{edge}: scheduled #{boundary.nominal_local_date} #{nominal_time} #{zone} → #{local_time(
        boundary.resolved_at, zone
      )}, #{offset_text}; #{resolution}, #{duration}."
    end

    def local_time(value, zone = nil, format: "%b %-d, %Y · %H:%M")
      return "—" unless value

      value = Time.iso8601(value) if value.is_a?(String)
      value.in_time_zone(zone || Munawaba.config.organization_time_zone).strftime(format)
    end

    def handoff_time(schedule)
      seconds = schedule.anchor_local_seconds.to_i
      format("%02d:%02d", seconds / 3600, seconds % 3600 / 60)
    end

    def cadence_name(schedule)
      CADENCES.fetch(schedule.cadence, schedule.cadence.to_s.humanize)
    end

    def nav_link(label, path, key)
      active = controller_name == key || (key == "schedules" && %w[rotations slack_integrations shifts
                                                                   overrides].include?(controller_name))
      link_to label, path, class: "mn-nav-link#{" mn-selected" if active}", aria: { current: ("page" if active) }
    end

    def model_errors(record, field)
      return unless record && record.errors[field].present?

      content_tag(:p, record.errors[field].join(", "), class: "mn-field-error",
                                                       id: "#{record.model_name.param_key}_#{field}_error")
    end

    def preview_value(key, default = nil)
      return default unless @preview

      value = @preview.public_send(key)
      value.nil? ? default : value
    end

    def detail_value(key, default = nil)
      details = preview_value(:details, {})
      details[key] || default
    end

    def projection_slots
      Array(preview_value(:projection, []))
    end

    def person_label(id)
      @mn_person_labels ||= Person.where(id: (projection_slots.map { |slot| slot[:effective_person_id] } +
        Array(detail_value(:ordered_person_ids)) + Array(detail_value(:schedule_plans)).flat_map { |plan|
                                                     Array(plan[:before_person_ids]) + Array(plan[:person_ids])
                                                   }).compact.uniq).pluck(:id, :name).to_h
      @mn_person_labels[id.to_i] || Person.where(id: id).pick(:name) || "Person ##{id}"
    end

    def confirmation_target
      case @operation.to_sym
      when :activate then [activate_schedule_path(@subject), :post]
      when :resume then [resume_schedule_path(@subject), :post]
      when :rotation then [schedule_rotation_path(@subject), :patch]
      when :deactivate then [deactivate_person_path(@subject), :patch]
      when :pause then [pause_schedule_path(@subject), :post]
      when :cancel_scheduled then [cancel_scheduled_schedule_path(@subject), :post]
      when :revoke then [revoke_shift_override_path(@subject), :patch]
      when :restore_to_base then [restore_shift_override_path(@subject), :patch]
      else [shift_override_path(@subject), :post]
      end
    end

    def proposal_heading
      { activate: "Review activation", resume: "Review resume", rotation: "Review rotation", deactivate: "Review deactivation",
        override: "Review override", revoke: "Review override revocation", restore_to_base: "Review restore to base",
        pause: "Review pause", cancel_scheduled: "Review scheduled cancellation" }.fetch(@operation.to_sym)
    end

    def proposal_back_path
      @subject.is_a?(Person) ? person_path(@subject) : @subject.is_a?(Shift) ? shift_path(@subject) : schedule_path(@subject)
    end

    def submitted_hidden_fields(attributes)
      safe_join(attributes.flat_map do |key, value|
        value.is_a?(Array) ? value.map { |item|
          hidden_field_tag("#{key}[]", item, id: nil)
        } : hidden_field_tag(key, value, id: nil)
      end)
    end

    def cursor_for(record, column)
      "#{record.public_send(column).utc.iso8601(6)}|#{record.id}"
    end

    def name_cursor_for(record)
      Base64.urlsafe_encode64(JSON.generate([record.name, record.id]), padding: false)
    end

    def calendar_link(date, view = @view)
      calendar_path(request.query_parameters.except("date", "until", "view").merge(date: date.iso8601, view: view))
    end

    def calendar_days
      first = @from.beginning_of_week(Munawaba.config.week_starts_on)
      last = (@until - 1).end_of_week(Munawaba.config.week_starts_on)
      (first..last).to_a
    end

    def future_boundaries(schedule)
      Timing::BoundaryCalculator.new(schedule).selectable_boundaries(now: Time.current).map do |boundary|
        [local_time(boundary.resolved_at, schedule.time_zone), boundary.index]
      end
    end

    def readable_conflict(conflict, zone)
      @mn_conflict_schedules ||= Schedule.where(id: Array(preview_value(:conflicts, [])).flat_map { |entry|
        [entry[0], entry[4]]
      }).pluck(:id, :name).to_h
      from = Time.at(Rational(conflict[9], 1_000_000)).utc
      until_at = Time.at(Rational(conflict[10], 1_000_000)).utc
      "#{person_label(conflict[8])} · #{@mn_conflict_schedules[conflict[0]]} and #{@mn_conflict_schedules[conflict[4]]} · #{local_time(
        from, zone
      )} – #{local_time(until_at, zone)} · #{zone}"
    end

    def shifts_on(day)
      zone = ActiveSupport::TimeZone[@time_zone]
      start_at = zone.local(day.year, day.month, day.day)
      next_day = day + 1
      end_at = zone.local(next_day.year, next_day.month, next_day.day)
      @shifts.select { |shift| shift.starts_at < end_at && shift.ends_at > start_at }
    end

    def conflicts_for(shifts)
      ids = shifts.map(&:id)
      return {} if ids.empty?

      sql = Shift.sanitize_sql_array([<<~SQL, ids])
        SELECT a.id, b.schedule_id, s.name FROM munawaba_shifts a
        JOIN munawaba_shifts b ON a.effective_person_id = b.effective_person_id AND a.schedule_id <> b.schedule_id
          AND b.canceled_at IS NULL AND tstzrange(a.starts_at, a.ends_at, '[)') && tstzrange(b.starts_at, b.ends_at, '[)')
        JOIN munawaba_schedules s ON s.id = b.schedule_id WHERE a.id IN (?) AND a.canceled_at IS NULL
      SQL
      Shift.connection.select_all(sql).to_a.group_by { |row| row["id"].to_i }
    end
  end
end
