# frozen_string_literal: true

module Munawaba
  module Slack
    class Renderer
      LABELS = { "advance_reminder" => "Upcoming on-call shift", "shift_start" => "On-call shift started",
                 "assignment_change" => "On-call assignment changed", "next_assignment_change" => "Next assignment changed",
                 "test" => "Munawaba test message" }.freeze

      def self.escape(value, limit: 255)
        value.to_s.truncate(limit, omission: "…").gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      def self.person(person)
        id = person.slack_member_id
        id.present? && id.match?(/\A[A-Z][A-Z0-9]{1,31}\z/) ? "<@#{id}>" : escape(person.name)
      end

      def self.call(delivery:, schedule:, shift: nil)
        context = Notifications::Context::V1.validate!(kind: delivery.kind, context: delivery.context)
        lines = ["#{LABELS.fetch(delivery.kind)} · #{escape(schedule.name, limit: 120)}"]
        if delivery.kind == "assignment_change"
          previous, current = Person.find(context.fetch("previous_person_id")),
Person.find(context.fetch("new_person_id"))
          lines << "#{person(previous)} → #{person(current)}"
          override = ShiftOverride.find(context["override_id"] || context.fetch("ended_override_id"))
          lines << "Reason: #{escape(override.reason, limit: 500)}" if override.reason.present?
        elsif delivery.kind == "next_assignment_change"
          lines << "#{person(Person.find(context.fetch("previous_next_person_id")))} → #{person(Person.find(context.fetch("new_next_person_id")))}"
          shift ||= Shift.find(context.fetch("described_shift_id"))
        elsif shift
          lines << "On call: #{person(shift.effective_person)}"
        end
        if shift
          zone = ActiveSupport::TimeZone[schedule.time_zone]
          lines << "#{shift.starts_at.in_time_zone(zone).strftime("%b %-d, %Y %H:%M")} – #{shift.ends_at.in_time_zone(zone).strftime("%b %-d, %Y %H:%M")} (#{escape(schedule.time_zone)})"
        else
          lines << "Timezone: #{escape(schedule.time_zone)}"
        end
        if Munawaba.config.application_base_url
          base = Munawaba.config.application_base_url.sub(%r{/+\z}, "")
          lines << "<#{base}/schedules/#{schedule.id}|View schedule>"
        end
        { text: lines.join("\n"), unfurl_links: false, unfurl_media: false }
      end
    end
  end
end
