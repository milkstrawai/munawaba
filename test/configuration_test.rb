require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "default configuration is valid and missing host callbacks are not silently authorized" do
    config = Munawaba::Configuration.new
    assert_same config, config.validate!
    assert_nil config.authenticate
    assert_nil config.authorize
    refute config.notifications_enabled?
  end

  test "invalid calendar timezone queue and Slack host settings are rejected" do
    cases = { calendar_future_limit: 14.months, calendar_past_limit: 0, calendar_max_span: -1,
              organization_time_zone: "Not/AZone", default_schedule_time_zone: "Mars", week_starts_on: :someday,
              job_queue_name: "", slack_allowed_hosts: ["*.slack.com"], notifications_enabled: ->(_x) { true } }
    cases.each do |key, value|
      config = Munawaba::Configuration.new
      config.public_send("#{key}=", value)
      assert_raises(Munawaba::ConfigurationError, key.to_s) { config.validate! }
    end
  end

  test "trusted base URLs reject untrusted transport userinfo query fragment and controls" do
    ["http://public.example/on-call", "https://user:pass@example.org/on-call", "https://example.org/on-call?q=1",
     "https://example.org/on-call#fragment", "/on-call", "https://example.org/\n"].each do |url|
      config = Munawaba::Configuration.new
      config.application_base_url = url
      assert_raises(Munawaba::ConfigurationError) { config.validate! }
    end
    ["https://example.org/custom/on-call", "http://localhost:3100/on-call"].each do |url|
      config = Munawaba::Configuration.new
      config.application_base_url = url
      assert config.validate!
    end
  end
end
