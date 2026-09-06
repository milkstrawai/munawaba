# frozen_string_literal: true

module Munawaba
  # Ruby entry point for trusted host code. HTTP requests pass through the
  # engine's authentication and authorization callbacks before reaching here.
  class Commands
    class Stale < StandardError; end
    class Invalid < StandardError; end
    class Rediscover < StandardError; end
    SIMPLE = %w[create_person update_person reactivate create_schedule update_schedule].freeze
    attr_reader :operation, :subject, :attributes, :actor

    def self.preview(operation:, subject:, attributes: {}, actor: nil)
      ActiveRecord::Base.uncached do
        new(operation: operation, subject: subject, attributes: attributes, actor: actor).preview
      end
    end

    def self.call(operation:, subject:, attributes: {}, actor: nil, token: nil, acknowledge_conflicts: false)
      ActiveRecord::Base.uncached do
        new(operation: operation, subject: subject, attributes: attributes, actor: actor).call(token: token,
                                                                                               acknowledge_conflicts: acknowledge_conflicts)
      end
    end

    def initialize(operation:, subject:, attributes: {}, actor: nil)
      @operation, @subject, @attributes, @actor = operation.to_s, subject, attributes.to_h.symbolize_keys, actor
      @operation_id = SecureRandom.uuid
    end

    def preview
      return failure(422, "Administrative changes are temporarily unavailable.") if maintenance?

      subject.reload if subject.persisted?
      plan = build(now: Canonical.time(Time.current))
      render_plan(plan)
    rescue Invalid, ArgumentError, TypeError, ActiveRecord::RecordInvalid, Stale => error
      failure(422,
              error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages : error.message.presence || "The requested action is no longer available.")
    end

    def call(token:, acknowledge_conflicts:)
      return failure(422, "Administrative changes are temporarily unavailable.") if maintenance?
      return simple_change if SIMPLE.include?(operation)

      envelope = verifier.verified(token.to_s, purpose: "munawaba.#{operation}")
      raise Stale unless envelope.is_a?(Hash) && envelope["schema_version"] == 1 && envelope["operation"] == operation && envelope["target_id"] == subject.id

      attempts = 0
      begin
        ids = discover
        ActiveRecord::Base.transaction(requires_new: true) do
          now, locked_shifts = lock_rows(ids)
          subject.reload
          raise Rediscover unless complete_discovery?(ids, discover)

          begin
            plan = build(now: now, envelope: envelope, locked_shifts: locked_shifts)
          rescue Invalid, ArgumentError, TypeError
            raise Stale
          end
          raise Stale unless Canonical.equal?(Canonical.digest(plan[:evidence]), Canonical.digest(envelope["evidence"]))
          raise Invalid, "Resolve the listed blockers before confirming." if plan[:blockers].present?
          raise Invalid, "Acknowledge the assignment conflicts to continue." if plan[:conflicts].any? && !ActiveModel::Type::Boolean.new.cast(acknowledge_conflicts)

          apply_plan(plan, now: now)
          Result.new(status: 303, record: subject, errors: [])
        end
      rescue Rediscover
        attempts += 1
        retry if attempts < 4
        raise Stale
      end
    rescue Stale, ActiveRecord::StaleObjectError
      refreshed = stale_preview
      Result.new(status: 409, record: subject,
                 errors: ["This confirmation is out of date. Review the refreshed preview and confirm again."], preview: refreshed.preview)
    rescue Invalid, ArgumentError, TypeError, ActiveRecord::RecordInvalid => error
      failure(422, error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages : error.message,
              refresh: true)
    rescue ActiveRecord::RecordNotUnique
      failure(422, "That name, email, or Slack member ID is already in use.")
    end

    private

    def stale_preview
      refreshed = preview
      return refreshed if refreshed.preview

      fallback = case operation
                 when "cancel_scheduled" then "pause"
                 when "pause" then "cancel_scheduled"
                 when "revoke" then "restore_to_base"
                 when "restore_to_base" then "revoke"
                 when "resume" then "resume"
                 end
      return refreshed unless fallback

      next_attributes = fallback == "resume" ? attributes.except(:boundary_index) : attributes
      self.class.preview(operation: fallback, subject: subject, attributes: next_attributes, actor: actor)
    end

    def maintenance? = Munawaba.config.maintenance_mode?

    def verifier
      @verifier ||= ActiveSupport::MessageVerifier.new(
        Rails.application.key_generator.generate_key("munawaba.proposals.v1", 32), digest: "SHA256", serializer: JSON
      )
    end

    def failure(status, errors, refresh: false)
      refreshed = refresh ? preview : nil
      Result.new(status: status, record: subject, errors: Array(errors), preview: refreshed&.preview)
    end

    def render_plan(plan)
      envelope = { schema_version: 1, operation: operation, target_id: subject.id, evidence: plan[:evidence],
                   hints: plan[:hints] || {} }
      token = plan[:timing_blocker] ? nil : verifier.generate(envelope, purpose: "munawaba.#{operation}")
      preview = Preview.new(token: token, projection: plan[:slots], conflicts: plan[:conflicts],
                            details: plan[:details].merge(operation: operation, blockers: plan[:blockers] || []))
      Result.new(status: 200, record: subject, errors: [], preview: preview)
    end

    def schedule
      subject.is_a?(Schedule) ? subject : subject.is_a?(Shift) ? subject.schedule : nil
    end

    def candidate_schedules
      membership_ids = ScheduleMembership.where(person_id: subject.id).pluck(:schedule_id)
      override_ids = ShiftOverride.joins(shift: :schedule).where(replacement_person_id: subject.id, ended_at: nil)
                                  .where(munawaba_shifts: { canceled_at: nil }).where(munawaba_schedules: { state: %w[
                                                                                        scheduled active
                                                                                      ] })
                                  .where("munawaba_shifts.coverage_revision = munawaba_schedules.coverage_revision").pluck("munawaba_shifts.schedule_id")
      (membership_ids + override_ids).uniq.sort
    end

    def discover
      schedules = operation == "deactivate" ? candidate_schedules : [schedule&.id].compact
      memberships = ScheduleMembership.where(schedule_id: schedules)
      shifts = Shift.where(schedule_id: schedules,
                           canceled_at: nil).where("coverage_revision = (SELECT coverage_revision FROM munawaba_schedules WHERE munawaba_schedules.id = munawaba_shifts.schedule_id)")
      overrides = ShiftOverride.where(shift_id: shifts.select(:id), ended_at: nil)
      people = memberships.pluck(:person_id) + shifts.pluck(:base_person_id,
                                                            :effective_person_id).flatten + overrides.pluck(
                                                              :previous_person_id, :replacement_person_id
                                                            ).flatten
      people += Array(attributes[:person_ids]).reject(&:blank?).map { |id| Integer(id) }
      people << Integer(attributes[:person_id]) if attributes[:person_id].present?
      people << subject.id if subject.is_a?(Person)
      { people: people.compact.uniq.sort, schedules: schedules, memberships: memberships.pluck(:id).sort,
        shifts: shifts.pluck(:id).sort, overrides: overrides.pluck(:id).sort,
        deliveries: NotificationDelivery.where(schedule_id: schedules, status: %w[pending enqueued processing]).pluck(:id).sort }
    end

    def lock_rows(ids)
      Person.where(id: ids[:people]).order(:id).lock("FOR NO KEY UPDATE").load
      Schedule.where(id: ids[:schedules]).order(:id).lock("FOR NO KEY UPDATE").load
      # Capture one time after locking people and schedules, before child rows.
      now = Canonical.time(Time.current)
      ScheduleMembership.where(id: ids[:memberships]).order(:id).lock("FOR UPDATE").load
      shifts = Shift.where(id: ids[:shifts]).order(:id).lock("FOR NO KEY UPDATE").to_a
      ShiftOverride.where(id: ids[:overrides]).order(:id).lock("FOR NO KEY UPDATE").load
      NotificationDelivery.where(id: ids[:deliveries]).order(:id).lock("FOR NO KEY UPDATE").load
      [now, shifts]
    end

    def complete_discovery?(locked, current)
      current.all? { |kind, ids| (ids - locked.fetch(kind)).empty? }
    end

    def roster_for(item)
      ScheduleMembership.where(schedule_id: item.id).order(:position, :id).pluck(:person_id)
    end

    def order_for(item, required: false)
      ids = attributes.key?(:person_ids) ? Array(attributes[:person_ids]).reject(&:blank?).map { |id|
        Integer(id)
      } : roster_for(item)
      validate_order!(ids, required: required)
      ids
    end

    def validate_order!(ids, required:)
      raise Invalid, "Choose at least one active person and make Next explicit." if required && ids.empty?
      raise Invalid, "A rotation cannot contain a person twice." unless ids.uniq == ids
      raise Invalid,
            "A rotation can contain at most #{Defaults::MAXIMUM_SCHEDULE_MEMBERS} people." if ids.length > Defaults::MAXIMUM_SCHEDULE_MEMBERS
      raise Invalid, "Only active people can receive new assignments." unless Person.where(id: ids,
                                                                                           active: true).count == ids.length
    end

    def prepare(item, now, locked_shifts)
      Shifts::NormalizeFutureTiming.prepare(schedule: item, now: now, shifts: locked_shifts&.select { |row|
        row.schedule_id == item.id
      })
    end

    def build(now:, envelope: nil, locked_shifts: nil)
      case operation
      when "activate", "resume" then build_run(now, envelope)
      when "rotation" then build_rotation(now, locked_shifts)
      when "override", "revoke", "restore_to_base" then build_override(now, locked_shifts)
      when "pause", "cancel_scheduled" then build_lifecycle(now, locked_shifts)
      when "deactivate" then build_deactivation(now, locked_shifts)
      else raise Invalid, "Unknown command."
      end
    end

    def evidence(expected, proposal, conflicts, extra = nil)
      [expected, Canonical.digest(proposal), extra, Canonical.digest(conflicts)]
    end

    def build_run(now, envelope)
      item = schedule
      required_state = operation == "activate" ? "draft" : "paused"
      raise Invalid, "The schedule must be #{required_state} before #{operation}." unless item.state == required_state

      ids = order_for(item, required: true)
      raise Invalid, "Save the rotation before activation." if operation == "activate" && ids != roster_for(item)

      calculator = Timing::BoundaryCalculator.new(item)
      hints = envelope ? envelope.fetch("hints") : {}
      if operation == "activate"
        kind = calculator.boundary(0).resolved_at > now ? "future_activation" : "immediate_activation"
        boundary = kind == "future_activation" ? 0 : calculator.slot_at(now)
        fixed = kind == "immediate_activation" ? (hints["conflict_check_at"] ? Canonical.from_micros(hints["conflict_check_at"]) : now) : nil
        raise Stale if envelope && (hints["kind"] != kind || hints["boundary_index"] != boundary)
      else
        kind = "resume"
        boundary = attributes[:boundary_index].present? ? Integer(attributes[:boundary_index]) : calculator.selectable_boundaries(now: now).first&.index
        raise Invalid, "Choose an available handoff to resume coverage." if boundary.nil?

        fixed = nil
      end
      boundary_at = calculator.boundary(boundary).resolved_at
      if kind != "immediate_activation"
        raise(envelope ? Stale : Invalid,
              "The selected start is outside the selectable future window.") unless boundary_at >= now && boundary_at <= now + Munawaba.config.calendar_future_limit
      end
      plan = Shifts::ProjectionPlan.new(schedule: item, operation_kind: kind, now: now, person_ids: ids,
                                        first_boundary: boundary, target_boundary: hints["target_boundary"], conflict_check_at: fixed)
      if envelope
        floor = Shifts::ProjectionPlan.target(calculator, boundary, now + Munawaba.config.calendar_future_limit)
        raise Stale unless plan.target_boundary >= floor

        plan.persistence_slots(now: now)
      end
      expected = item.slice(:lock_version, :lifecycle_revision, :coverage_revision, :rotation_revision)
      proposal = if operation == "activate"
                   [item.id, kind == "immediate_activation" ? "immediate" : "future", boundary, fixed && Canonical.micros(fixed),
                    ids, plan.target_boundary, plan.digest]
                 else
                   [item.id, boundary, ids, plan.target_boundary, plan.digest]
                 end
      conflicts = Conflicts::Finder.call(slots: plan.slots)
      { evidence: evidence(expected, proposal, conflicts, plan.digest), slots: plan.slots,
        conflicts: conflicts, plan: plan, person_ids: ids, hints: { kind: kind, boundary_index: boundary, target_boundary: plan.target_boundary, conflict_check_at: fixed && Canonical.micros(fixed) },
        details: { state: plan.state, ordered_person_ids: ids, boundary_index: boundary, generated_through_boundary: plan.target_boundary, resolved_boundaries: plan.boundaries } }
    end

    def temporal_class(slot, now)
      return "completed" if slot[:ends_at] <= now

      slot[:starts_at] > now ? "future" : "current"
    end

    def effective_boundary(item, slots, now)
      case item.state
      when "active"
        current = slots.find { |slot| temporal_class(slot, now) == "current" }
        raise Invalid, "Projection maintenance is required to establish current coverage." unless current

        [current[:boundary_index] + 1, current[:ends_at]]
      when "scheduled" then [item.coverage_start_boundary, item.coverage_starts_at]
      else [nil, nil]
      end
    end

    def regenerated(item, prepared, ids, boundary, instant, now)
      return [] if boundary.nil?

      calculator = Timing::BoundaryCalculator.new(item)
      target = [item.generated_through_boundary || boundary,
                Shifts::ProjectionPlan.target(calculator, item.coverage_start_boundary,
                                              now + Defaults::SHIFT_GENERATION_HORIZON)].max
      existing = prepared.slots.index_by { |slot| slot[:boundary_index] }
      active_overrides = ShiftOverride.where(shift_id: prepared.rows.map(&:id), ended_at: nil).index_by(&:shift_id)
      (boundary..target).map do |index|
        old = existing[index]
        base = ids[(index - boundary) % ids.length]
        override = old && active_overrides[old[:id]]
        effective = override ? override.replacement_person_id : base
        starts = index == boundary ? instant : calculator.boundary(index).resolved_at
        ends = calculator.boundary(index + 1).resolved_at
        raise Invalid, "Timing maintenance would create a non-positive shift." unless ends > starts

        { id: old&.dig(:id), schedule_id: item.id, coverage_revision: item.coverage_revision, boundary_index: index,
          starts_at: starts, ends_at: ends, base_person_id: base, effective_person_id: effective,
          rotation_revision: item.rotation_revision + 1, assignment_version: old ? old[:assignment_version] + (old[:effective_person_id] == effective ? 0 : 1) : 1,
          timing_version: old ? old[:timing_version] + (old[:starts_at] == starts && old[:ends_at] == ends ? 0 : 1) : 1,
          active_override_id: override&.id }
      end
    end

    def build_rotation(now, locked)
      item = schedule
      prepared = prepare(item, now, locked)
      virtual = prepared.virtual_schedule
      ids = order_for(item, required: %w[active scheduled].include?(virtual.state))
      boundary, instant = effective_boundary(virtual, prepared.slots, now)
      next_slot = prepared.slots.find { |slot| slot[:starts_at] > now }
      next_persisted = next_slot && prepared.rows.find { |row| row.id == next_slot[:id] }
      expected = item.slice(:lifecycle_revision, :coverage_revision, :rotation_revision,
                            :cadence, :time_zone, :anchor_local_date, :anchor_local_seconds)
      expected.merge!("next_shift_id" => next_slot&.dig(:id), "next_shift_timing_version" => next_persisted&.timing_version)
      slots = regenerated(virtual, prepared, ids, boundary, instant, now)
      final_slots = (prepared.changes + slots).index_by { |slot| [slot[:schedule_id], slot[:boundary_index]] }.values
      all_conflicts = Conflicts::Finder.call(slots: final_slots)
      prepared.conflicts = all_conflicts
      conflicts = conflicts_for(all_conflicts, slots)
      extra = Canonical.digest([virtual.state, virtual.lifecycle_revision, normalized_slots(prepared.slots),
                                normalized_slots(slots)])
      { evidence: evidence(expected, [item.id, boundary, ids], conflicts, extra), slots: slots, conflicts: conflicts,
        prepared: prepared, person_ids: ids, before_ids: roster_for(item), boundary: boundary, instant: instant,
        details: { state: virtual.state, ordered_person_ids: ids, boundary_index: boundary, effective_at: instant,
                   generated_through_boundary: slots.last&.dig(:boundary_index) || virtual.generated_through_boundary } }
    end

    def build_override(now, locked)
      item = schedule
      prepared = prepare(item, now, locked)
      slot = prepared.slots.find { |entry| entry[:id] == subject.id }
      raise Invalid,
            "Canceled and historical runs cannot be overridden." unless slot && subject.coverage_revision == item.coverage_revision

      klass = temporal_class(slot, now)
      raise Invalid, "Completed shifts cannot be changed." if klass == "completed"

      active_override = ShiftOverride.find_by(shift_id: subject.id, ended_at: nil)
      expected = { "expected_coverage_revision" => subject.coverage_revision, "expected_assignment_version" => subject.assignment_version,
                   "expected_timing_version" => subject.timing_version, "expected_base_person_id" => subject.base_person_id,
                   "expected_shift_temporal_class" => klass }
      if operation == "override"
        person_id = Integer(attributes[:person_id])
        raise Invalid, "Choose a different active person." unless Person.where(id: person_id,
                                                                               active: true).exists? && person_id != slot[:effective_person_id]

        reason = attributes[:reason].to_s.strip.presence
        raise Invalid, "Reason must be no longer than 1,000 characters." if reason && reason.length > 1000

        proposal = [subject.id, "apply", person_id, reason]
      else
        raise Invalid, "This shift has no override to end." unless active_override

        required_class = operation == "revoke" ? "future" : "current"
        raise Invalid, "This action requires a #{required_class} shift." unless klass == required_class

        person_id = slot[:base_person_id]
        raise Invalid, "The base person is inactive. Choose an active replacement." unless Person.where(id: person_id,
                                                                                                        active: true).exists?

        proposal = [subject.id, operation, active_override.id]
      end
      proposed = slot.merge(effective_person_id: person_id,
                            assignment_version: slot[:assignment_version] + (slot[:effective_person_id] == person_id ? 0 : 1))
      final_slots = (prepared.changes + [proposed]).index_by { |entry|
        [entry[:schedule_id], entry[:boundary_index]]
      }.values
      all_conflicts = Conflicts::Finder.call(slots: final_slots)
      prepared.conflicts = all_conflicts
      conflicts = slot[:effective_person_id] == person_id ? [] : conflicts_for(all_conflicts, [proposed])
      extra = Canonical.digest([prepared.virtual_schedule.state, prepared.virtual_schedule.lifecycle_revision,
                                normalized_slots(prepared.slots), active_override&.id])
      { evidence: evidence(expected, proposal, conflicts, extra), slots: [proposed], conflicts: conflicts,
        prepared: prepared, active_override: active_override, previous_person_id: slot[:effective_person_id], person_id: person_id, reason: reason,
        details: { state: prepared.virtual_schedule.state, temporal_class: klass, base_person_id: slot[:base_person_id], person_id: person_id } }
    end

    def build_lifecycle(now, locked)
      item = schedule
      prepared = prepare(item, now, locked)
      virtual = prepared.virtual_schedule
      if operation == "pause"
        raise Invalid, "Only current active coverage can be paused." unless virtual.state == "active"

        current = prepared.slots.find { |slot| temporal_class(slot, now) == "current" }
        raise Invalid, "Projection maintenance is required to find current coverage." unless current

        persisted = prepared.rows.find { |row| row.id == current[:id] }
        expected = { "expected_lifecycle_revision" => item.lifecycle_revision,
                     "expected_current_shift_id" => current[:id], "expected_current_shift_timing_version" => persisted.timing_version }
        target = current
      else
        raise Stale unless item.state == "scheduled" && virtual.state == "scheduled" && !prepared.clipping

        target = prepared.slots.first
        persisted = prepared.rows.first
        expected = { "expected_lifecycle_revision" => item.lifecycle_revision, "expected_coverage_revision" => item.coverage_revision,
                     "expected_first_shift_id" => persisted.id, "expected_first_shift_timing_version" => persisted.timing_version }
      end
      prepared.conflicts = Conflicts::Finder.call(slots: prepared.changes) if operation == "pause" && prepared.changes.any?
      # Cancel future coverage using its saved boundary, without applying new timezone rules.
      extra = operation == "pause" ? [virtual.state, target[:id], Canonical.micros(target[:ends_at]),
                                      target[:timing_version]] : [virtual.state, target[:id],
                                                                  virtual.coverage_start_boundary]
      { evidence: evidence(expected, [item.id, operation], [], extra), slots: [target], conflicts: [],
        prepared: prepared, target: target, details: { state: virtual.state, effective_at: operation == "pause" ? target[:ends_at] : now } }
    end

    def conflicts_for(conflicts, slots)
      identities = slots.map { |slot| [slot[:schedule_id], slot[:coverage_revision], slot[:boundary_index]] }.to_set
      conflicts.select { |entry|
        identities.include?([entry[0], entry[2], entry[3]]) || identities.include?([entry[4], entry[6], entry[7]])
      }
    end

    def normalized_slots(slots)
      override_ids = ShiftOverride.where(shift_id: slots.filter_map { |slot|
        slot[:id]
      }, ended_at: nil).pluck(:shift_id, :id).to_h
      slots.sort_by { |slot| [slot[:boundary_index], slot[:id] || -1] }.map do |slot|
        [slot[:id], slot[:coverage_revision], slot[:boundary_index], Canonical.micros(slot[:starts_at]), Canonical.micros(slot[:ends_at]),
         slot[:base_person_id], slot[:effective_person_id], slot[:rotation_revision], slot[:assignment_version], slot[:timing_version],
         slot.key?(:active_override_id) ? slot[:active_override_id] : override_ids[slot[:id]]]
      end
    end

    def shift_ref(slot)
      return nil unless slot

      [slot[:id], slot[:coverage_revision], slot[:boundary_index], Canonical.micros(slot[:starts_at]),
       Canonical.micros(slot[:ends_at]), slot[:timing_version], slot[:base_person_id], slot[:effective_person_id], slot[:assignment_version]]
    end

    def build_deactivation(now, locked)
      raise Invalid, "This person is already inactive." unless subject.active?

      schedule_plans = []
      canonical_plans = []
      blockers = []
      Schedule.where(id: candidate_schedules).order(:id).each do |item|
        prepared = prepare(item, now, locked)
        virtual = prepared.virtual_schedule
        memberships = ScheduleMembership.where(schedule_id: item.id).order(:position, :id).includes(:person).to_a
        before_ids = memberships.map(&:person_id)
        member = before_ids.include?(subject.id)
        active_overrides = ShiftOverride.where(shift_id: prepared.rows.map(&:id), replacement_person_id: subject.id, ended_at: nil).order(
          :shift_id, :id
        ).to_a
        override_blockers = active_overrides.filter_map do |override|
          slot = prepared.slots.find { |entry| entry[:id] == override.shift_id }
          next unless slot && temporal_class(slot, now) == "future"

          [override.id, slot[:id], slot[:coverage_revision], slot[:boundary_index], override.replacement_person_id,
           slot[:assignment_version], slot[:timing_version], Canonical.micros(slot[:starts_at])]
        end
        local_blockers = []
        local_blockers << "Replace or revoke this person's future overrides." if override_blockers.any?
        local_blockers << "Timing maintenance must finish before deactivation." if prepared.clipping
        ids = before_ids - [subject.id]
        boundary, instant = member ? effective_boundary(virtual, prepared.slots, now) : [nil, nil]
        empty = member && %w[active scheduled].include?(virtual.state) && ids.empty?
        local_blockers << "An active or scheduled rotation needs at least one member." if empty
        if member && boundary && ids.any?
          old_next_index = (boundary - virtual.rotation_effective_boundary) % before_ids.length
          cycle = before_ids.rotate(old_next_index)
          successor = cycle.find { |id| id != subject.id && Person.find(id).active? }
          raise Invalid, "The surviving rotation contains an inactive person." unless successor

          ids = ids.rotate(ids.index(successor))
        else
          successor = nil
        end
        regenerated_slots = member && boundary && !empty ? regenerated(virtual, prepared, ids, boundary, instant,
                                                                       now) : []
        all_slots = (prepared.slots.index_by { |slot| slot[:boundary_index] }.merge(regenerated_slots.index_by { |slot|
          slot[:boundary_index]
        })).values.sort_by { |slot| slot[:boundary_index] }
        current = all_slots.find { |slot| temporal_class(slot, now) == "current" }
        next_slot = all_slots.find { |slot| slot[:starts_at] > now }
        plan = { schedule: item, prepared: prepared, member: member, before_ids: before_ids, person_ids: ids, boundary: boundary,
                 instant: instant, successor: successor, slots: regenerated_slots, blockers: local_blockers }
        schedule_plans << plan
        canonical_plans << [item.id, member ? "deactivation" : "normalization_only", member, virtual.state, virtual.lifecycle_revision,
                            virtual.coverage_revision, virtual.rotation_revision + (member ? 1 : 0), regenerated_slots.last&.dig(:boundary_index) || virtual.generated_through_boundary,
                            memberships.map { |membership|
                              [membership.id, membership.person_id, membership.position, membership.person.deactivated_at && Canonical.micros(membership.person.deactivated_at)]
                            },
                            shift_ref(current), shift_ref(next_slot), Canonical.digest(normalized_slots(all_slots)), override_blockers, ids, successor,
                            boundary, instant && Canonical.micros(instant), empty]
        blockers.concat(local_blockers.map { |text| "#{item.name}: #{text}" })
      end
      slots = schedule_plans.flat_map { |plan|
        (plan[:slots] + plan[:prepared].changes).uniq { |slot|
          [slot[:schedule_id], slot[:boundary_index]]
        }
      }
      conflicts = Conflicts::Finder.call(slots: slots)
      schedule_plans.each do |entry|
        entry[:prepared].conflicts = conflicts.select { |conflict|
          conflict[0] == entry[:schedule].id || conflict[4] == entry[:schedule].id
        }
      end
      digest = Canonical.digest([1, subject.id, canonical_plans])
      expected = { "expected_person_lock_version" => subject.lock_version }
      { evidence: evidence(expected, [subject.id], conflicts, digest), slots: slots, conflicts: conflicts,
        schedule_plans: schedule_plans, blockers: blockers,
        timing_blocker: schedule_plans.any? { |entry| entry[:prepared].clipping },
        details: { schedule_plans: schedule_plans.map { |plan|
          { schedule_id: plan[:schedule].id, name: plan[:schedule].name,
            before_person_ids: plan[:before_ids], person_ids: plan[:person_ids], successor_person_id: plan[:successor], effective_boundary: plan[:boundary],
            effective_at: plan[:instant], blockers: plan[:blockers], projection: plan[:slots].first(6) }
        } } }
    end

    def audit(event, schedule: nil, person: nil, shift: nil, metadata:, now:)
      Audit::Recorder.record!(event_type: event, actor: actor,
                              operation_id: @operation_id, occurred_at: now, schedule: schedule, person: person, shift: shift, metadata: metadata)
    end

    def notifications(item, now, **options)
      Notifications::Planner.call(schedule: item, now: now, **options)
    end

    def rewrite_memberships(item, ids)
      memberships = ScheduleMembership.where(schedule_id: item.id).order(:position, :id).to_a
      offset = [memberships.map(&:position).max || 0, ids.length].max + memberships.length + 1
      memberships.each_with_index { |membership, index| membership.update!(position: offset + index) }
      memberships.reject { |membership| ids.include?(membership.person_id) }.each(&:destroy!)
      existing = memberships.index_by(&:person_id)
      ids.each_with_index do |id, position|
        membership = existing[id]
        membership ? membership.update!(position: position) : ScheduleMembership.create!(schedule_id: item.id,
                                                                                         person_id: id, position: position)
      end
    end

    def apply_plan(plan, now:)
      case operation
      when "activate", "resume" then apply_run(plan, now)
      when "rotation"
        Shifts::NormalizeFutureTiming.apply!(plan[:prepared], now: now, operation_id: @operation_id, defer: true)
        apply_rotation(plan, now)
      when "override", "revoke", "restore_to_base"
        Shifts::NormalizeFutureTiming.apply!(plan[:prepared], now: now, operation_id: @operation_id, defer: true)
        apply_override(plan, now)
      when "pause", "cancel_scheduled" then apply_lifecycle(plan, now)
      when "deactivate" then apply_deactivation(plan, now)
      end
    end

    def lifecycle_metadata(item, first, before)
      { state_before: before, state_after: item.state, coverage_starts_at: item.coverage_starts_at,
        next_person_id: first.base_person_id }
    end

    def apply_run(plan, now)
      item = schedule
      projection = plan[:plan]
      before = item.state
      rewrite_memberships(item, plan[:person_ids]) if operation == "resume"
      rows = Shift.persist_projection!(schedule: item, slots: projection.persistence_slots(now: now), now: now)
      first = rows.first
      item.assign_attributes(state: projection.state, coverage_revision: projection.coverage_revision, rotation_revision: projection.rotation_revision,
                             coverage_start_boundary: projection.first_boundary, coverage_starts_at: first.starts_at,
                             generated_through_boundary: projection.target_boundary, rotation_effective_boundary: projection.first_boundary,
                             lifecycle_revision: item.lifecycle_revision + 1)
      item.first_activated_at ||= first.starts_at if item.state == "active"
      item.save!
      notifications(item, now, operation: operation, shifts: rows)
      event = item.state == "scheduled" ? (operation == "activate" ? "schedule.activation_scheduled" : "schedule.resume_scheduled") : (operation == "activate" ? "schedule.activated" : "schedule.resumed")
      audit(event, schedule: item, shift: first, now: now,
                   metadata: lifecycle_metadata(item, first, before))
      schedule_id, revision = item.id, item.coverage_revision
      ActiveRecord.after_all_transactions_commit do
        begin
          job = MaintainProjectionJob.perform_later(schedule_id, revision)
          ActiveSupport::Notifications.instrument("projection.enqueue_failed.munawaba",
                                                  schedule_id: schedule_id) unless job && job.successfully_enqueued?
        rescue StandardError
          ActiveSupport::Notifications.instrument("projection.enqueue_failed.munawaba", schedule_id: schedule_id)
        end
      end
    end

    def apply_rotation(plan, now, deactivated_person: nil)
      item = plan[:prepared].schedule
      before_next = plan[:boundary] && begin
        old = plan[:prepared].slots.find { |slot| slot[:boundary_index] == plan[:boundary] }
        old&.dig(:base_person_id)
      end
      rewrite_memberships(item, plan[:person_ids])
      rows = Shift.persist_projection!(schedule: item, slots: plan[:slots], now: now)
      item.rotation_revision += 1
      item.rotation_effective_boundary = plan[:boundary]
      item.generated_through_boundary = rows.last.boundary_index if rows.any?
      item.save!
      Shifts::NormalizeFutureTiming.finalize!(plan[:prepared], now: now, operation_id: @operation_id)
      notifications(item, now, operation: "rotation", shifts: rows, previous_person_id: before_next)
      metadata = { effective_at: plan[:instant], before_person_ids: plan[:before_ids],
                   after_person_ids: plan[:person_ids], next_person_id: plan[:boundary] && plan[:person_ids].first }
      metadata[:removed_person_id] = deactivated_person.id if deactivated_person
      audit(deactivated_person ? "rotation.changed_by_deactivation" : "rotation.replaced", schedule: item,
                                                                                           person: deactivated_person, now: now, metadata: metadata)
    end

    def apply_override(plan, now)
      item = schedule
      subject.reload
      ended = plan[:active_override]
      if ended
        ended.update!(ended_at: now,
                      end_reason: operation == "override" ? "superseded" : operation == "revoke" ? "revoked" : "restored_to_base")
      end
      fresh = if operation == "override"
                ShiftOverride.create!(shift: subject, previous_person_id: plan[:previous_person_id],
                                      replacement_person_id: plan[:person_id], reason: plan[:reason])
              end
      slot = plan[:slots].first
      subject.update!(effective_person_id: slot[:effective_person_id],
                      assignment_version: slot[:assignment_version]) if subject.effective_person_id != slot[:effective_person_id]
      Shifts::NormalizeFutureTiming.finalize!(plan[:prepared], now: now, operation_id: @operation_id)
      notifications(item, now, operation: operation, shifts: [subject],
                               previous_person_id: plan[:previous_person_id], override: fresh, ended_override: ended)
      metadata = { previous_person_id: plan[:previous_person_id], new_person_id: plan[:person_id] }
      if fresh && ended
        event = "override.superseded"
        metadata.merge!(ended_override_id: ended.id, new_override_id: fresh.id)
      elsif fresh
        event = "override.created"
        metadata[:override_id] = fresh.id
      else
        event = operation == "revoke" ? "override.revoked" : "override.restored_to_base"
        metadata[:override_id] = ended.id
      end
      audit(event, schedule: item, shift: subject, person: Person.find(plan[:person_id]), now: now, metadata: metadata)
    end

    def cancel_rows(item, rows, reason, now)
      rows.each do |row|
        override = ShiftOverride.find_by(shift_id: row.id, ended_at: nil)
        if override
          override.update!(ended_at: now, end_reason: "shift_canceled")
          audit("override.ended_by_shift_cancellation", schedule: item, shift: row, person: row.effective_person, now: now, metadata: {
                  override_id: override.id, cancellation_reason: reason
                })
        end
        row.update!(canceled_at: now, cancellation_reason: reason)
      end
      notifications(item, now, operation: "cancel", shifts: rows)
    end

    def apply_lifecycle(plan, now)
      item = schedule
      Shifts::NormalizeFutureTiming.apply!(plan[:prepared], now: now, operation_id: @operation_id, defer: true) if operation == "pause"
      before = item.state
      target = Shift.find(plan[:target][:id])
      if operation == "pause"
        rows = plan[:prepared].rows.select { |row| row.id != target.id && row.starts_at >= target.ends_at }
        cancel_rows(item, rows, "pause", now)
        Shifts::NormalizeFutureTiming.finalize!(plan[:prepared], now: now, operation_id: @operation_id)
        item.update!(state: "pausing", pause_effective_at: target.ends_at, rotation_effective_boundary: nil,
                     generated_through_boundary: target.boundary_index, lifecycle_revision: item.lifecycle_revision + 1)
        audit("schedule.pause_requested", schedule: item, shift: target, now: now, metadata: {
                state_before: before, state_after: item.state, pause_effective_at: target.ends_at,
                canceled_shift_count: rows.length
              })
      else
        rows = plan[:prepared].rows
        cancel_rows(item, rows, "scheduled_run_canceled", now)
        item.update!(state: item.first_activated_at ? "paused" : "draft", coverage_start_boundary: nil, coverage_starts_at: nil,
                     generated_through_boundary: nil, rotation_effective_boundary: nil, pause_effective_at: nil, lifecycle_revision: item.lifecycle_revision + 1)
        audit("schedule.scheduled_start_canceled", schedule: item, shift: target, now: now, metadata: {
                state_before: before, state_after: item.state, canceled_shift_count: rows.length
              })
      end
    end

    def apply_deactivation(plan, now)
      plan[:schedule_plans].each do |schedule_plan|
        Shifts::NormalizeFutureTiming.apply!(schedule_plan[:prepared], now: now, operation_id: @operation_id, defer: schedule_plan[:member])
        next unless schedule_plan[:member]

        apply_rotation(schedule_plan, now, deactivated_person: subject)
      end
      subject.update!(active: false, deactivated_at: now)
      ids = plan[:schedule_plans].map { |schedule_plan| schedule_plan[:schedule].id }.sort
      audit("person.deactivated", person: subject, now: now,
                                  metadata: { affected_schedule_count: ids.length, affected_schedule_ids: ids.first(100) })
    end

    def simple_change
      ActiveRecord::Base.transaction(requires_new: true) do
        subject.lock!("FOR NO KEY UPDATE") if subject.persisted?
        now = Canonical.time(Time.current)
        if operation.start_with?("update_")
          raise Stale unless attributes.key?(:lock_version) && Integer(attributes[:lock_version]) == subject.lock_version
        end
        case operation
        when "create_person", "update_person"
          subject.assign_attributes(attributes.slice(:name, :email, :slack_member_id))
          fields = subject.changes.keys.sort
          subject.save!
          if operation == "create_person"
            audit("person.created", person: subject, now: now,
                                    metadata: { active: subject.active?, slack_member_configured: subject.slack_member_id.present? })
          else
            audit("person.updated", person: subject, now: now, metadata: { changed_fields: fields })
          end
        when "reactivate"
          raise Invalid, "This person is already active." if subject.active?

          subject.update!(active: true, deactivated_at: nil)
          audit("person.reactivated", person: subject, now: now, metadata: { reactivated_at: Canonical.instant(now) })
        when "create_schedule", "update_schedule"
          keys = %i[name cadence time_zone anchor_local_date anchor_local_seconds]
          before = subject.attributes.slice(*keys.map(&:to_s))
          subject.assign_attributes(attributes.slice(*keys))
          changed = subject.changes.keys & keys.map(&:to_s)
          if operation == "update_schedule" && (changed - ["name"]).any? && (subject.state != "draft" || subject.first_activated_at)
            raise Invalid, "Timing can only change on a draft that has never started."
          end

          subject.save!
          after = subject.attributes.slice(*keys.map(&:to_s))
          [before, after].each { |values| values["anchor_local_date"] = values["anchor_local_date"]&.iso8601 }
          if operation == "create_schedule"
            audit("schedule.created", schedule: subject, now: now, metadata: after.merge("state" => subject.state))
          else
            audit("schedule.updated", schedule: subject, now: now,
                                      metadata: { changed_fields: changed.sort, before: before.slice(*changed), after: after.slice(*changed) })
          end
        end
      end
      Result.new(status: 303, record: subject, errors: [])
    end
  end
end
