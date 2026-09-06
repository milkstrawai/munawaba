Munawaba.configure do |config|
  config.parent_controller = "ApplicationController"

  # A callback must return exactly true to allow the request.
  config.authenticate = ->(_controller) { false }
  config.authorize = ->(_controller, _action, _record) { false }
  # Optional attribution for activity entries: {type: "User", id: user.id.to_s, name: user.name}
  config.actor = ->(_controller) { nil }

  # Full engine URL, including the mount path, for links in Slack messages.
  config.application_base_url = nil # "https://example.com/on-call"
  config.default_schedule_time_zone = "UTC"
  config.organization_time_zone = "UTC"
  config.week_starts_on = :monday
  config.job_queue_name = :munawaba

  # Slack delivery requires Active Record Encryption and a configured webhook.
  config.notifications_enabled = -> { ENV.fetch("MUNAWABA_NOTIFICATIONS_ENABLED", "false") == "true" }
  # Maintenance mode pauses scheduling changes and Slack delivery.
  # Before deploying timezone-data updates, follow:
  # https://github.com/milkstrawai/munawaba/blob/main/docs/usage.md#timezone-data-updates
  config.maintenance_mode = -> { ENV.fetch("MUNAWABA_MAINTENANCE_MODE", "false") == "true" }
end
