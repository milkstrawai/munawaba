# frozen_string_literal: true

module Munawaba
  module Integrations
    class Invalid < Munawaba::Error; end
    SETTINGS = %w[slack_enabled notify_advance advance_notice_seconds notify_shift_start notify_assignment_change
                  notify_next_assignment_change].freeze

    def self.call(operation:, schedule:, attributes: {}, actor: nil)
      operation = operation.to_s
      attributes = attributes.to_h.stringify_keys.slice(*SETTINGS, "slack_webhook_url", "lock_version")
      Schedule.transaction(requires_new: true) do
        current = Schedule.where(id: schedule.id).lock("FOR NO KEY UPDATE").first!
        check_version = attributes.key?("lock_version") && (operation == "update" || attributes["lock_version"])
        expected = attributes.delete("lock_version")
        if check_version && Integer(expected, exception: false) != current.lock_version
          message = operation == "update" ? "Review and save again." : "Review them again."
          next Result.new(status: 409, record: current, errors: ["Integration settings changed. #{message}"])
        end

        now = Time.current
        case operation
        when "update" then update(current, attributes, actor, now)
        when "remove" then remove(current, actor, now)
        when "test" then test(current, actor, now)
        else raise ArgumentError, "Unknown integration operation"
        end
        Result.new(status: 303, record: current, errors: [])
      end
    rescue ActiveRecord::RecordInvalid => error
      Result.new(status: 422, record: operation == "update" ? error.record : schedule,
                 errors: error.record.errors.full_messages)
    rescue Invalid => error
      Result.new(status: 422, record: schedule, errors: [error.message])
    end

    def self.update(current, attributes, actor, now)
      before = current.attributes.slice(*SETTINGS)
      old_timestamp = current.slack_webhook_configured_at
      webhook = attributes.delete("slack_webhook_url")
      if webhook.present?
        current.slack_webhook_url = webhook
        current.slack_webhook_configured_at = now
      end
      current.assign_attributes(attributes)
      return unless current.changed?

      save(current, now)
      changed = SETTINGS.select { |key| before[key] != current.public_send(key) }
      event_type = if webhook.present?
                     old_timestamp ? "slack.replaced" : "slack.configured"
                   else
                     "slack.settings_changed"
                   end
      Audit::Recorder.record!(event_type: event_type, schedule: current, actor: actor, occurred_at: now,
                              metadata: { changed_fields: changed, before: before.slice(*changed),
                                          after: current.attributes.slice(*changed) })
    end

    def self.remove(current, actor, now)
      raise Invalid, "No webhook is configured." unless current.slack_webhook_configured_at

      enabled = current.slack_enabled
      current.assign_attributes(slack_webhook_url: nil, slack_webhook_configured_at: nil, slack_enabled: false)
      save(current, now)
      Audit::Recorder.record!(event_type: "slack.removed", schedule: current, actor: actor, occurred_at: now,
                              metadata: { enabled_before: enabled })
    end

    def self.test(current, actor, now)
      unless current.slack_enabled && current.slack_webhook_configured_at
        raise Invalid, "Configure and enable Slack first."
      end

      row = NotificationDelivery.create!(schedule: current, kind: "test", status: "pending",
                                         event_key: "schedule:#{current.id}:test:notification:#{current.notification_revision}:#{SecureRandom.uuid}",
                                         notification_revision: current.notification_revision, context: Notifications::Context::V1.build(kind: "test"),
                                         due_at: now, next_attempt_at: now, expires_at: now + 10.minutes)
      Audit::Recorder.record!(event_type: "slack.test_requested", schedule: current, actor: actor, occurred_at: now,
                              metadata: { delivery_id: row.id })
      Notifications::WakeDispatcher.call
    end

    def self.save(current, now)
      old_intents = current.notification_deliveries.unsent.order(:id).lock("FOR NO KEY UPDATE").to_a
      current.notification_revision += 1
      current.save!
      PlannerEffects.replace_epoch(current, old_intents, now)
    end

    private_class_method :update, :remove, :test, :save
  end
end
