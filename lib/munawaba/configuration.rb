# frozen_string_literal: true

require "uri"

module Munawaba
  class Configuration
    ATTRIBUTES = %i[parent_controller authenticate authorize actor application_base_url
                    default_schedule_time_zone organization_time_zone week_starts_on job_queue_name
                    calendar_future_limit calendar_past_limit calendar_max_span notifications_enabled
                    slack_allowed_hosts maintenance_mode].freeze
    attr_accessor(*ATTRIBUTES)

    def initialize
      @parent_controller = "ApplicationController"
      @default_schedule_time_zone = @organization_time_zone = "UTC"
      @week_starts_on = :monday
      @job_queue_name = :munawaba
      @calendar_future_limit = 12.months
      @calendar_past_limit = 24.months
      @calendar_max_span = 3.months
      @notifications_enabled = false
      @maintenance_mode = false
      @slack_allowed_hosts = ["hooks.slack.com"]
    end

    def validate!
      raise ConfigurationError,
            "ActiveRecord.default_timezone must be :utc" unless ActiveRecord.default_timezone == :utc

      %i[default_schedule_time_zone organization_time_zone].each { |name| TZInfo::Timezone.get(public_send(name)) }
      %i[calendar_future_limit calendar_past_limit calendar_max_span].each do |name|
        value = public_send(name)
        raise ConfigurationError,
              "#{name} must be positive" unless value.respond_to?(:to_f) && value.to_f.finite? && value.to_f > 0
      end
      if calendar_future_limit > Defaults::SHIFT_GENERATION_HORIZON
        raise ConfigurationError, "calendar_future_limit exceeds the 13-month projection horizon"
      end
      raise ConfigurationError, "week_starts_on must be a weekday" unless Date::DAYS_INTO_WEEK.key?(week_starts_on)
      raise ConfigurationError, "job_queue_name is required" if job_queue_name.to_s.strip.empty?

      unless slack_allowed_hosts.is_a?(Array) && slack_allowed_hosts.present? && slack_allowed_hosts.all? { |host|
        host.is_a?(String) && host.match?(/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/)
      }
        raise ConfigurationError, "Slack hosts must be normalized exact hostnames"
      end

      %i[notifications_enabled maintenance_mode].each do |name|
        value = public_send(name)
        unless value == true || value == false || (value.respond_to?(:call) && value.respond_to?(:arity) && value.arity == 0)
          raise ConfigurationError, "#{name} must be boolean or a zero-argument callable"
        end
      end
      validate_base_url!
      self
    rescue TZInfo::InvalidTimezoneIdentifier
      raise ConfigurationError, "Timezones must be valid IANA identifiers"
    end

    def notifications_enabled?
      result = notifications_enabled.respond_to?(:call) ? notifications_enabled.call : notifications_enabled
      Munawaba.signal("notifications_disabled") unless result == true
      result == true && !maintenance_mode?
    rescue StandardError
      Munawaba.signal("notification_switch_error")
      false
    end

    def maintenance_mode?
      value = maintenance_mode.respond_to?(:call) ? maintenance_mode.call : maintenance_mode
      value != false
    rescue StandardError
      true
    end

    private

    def validate_base_url!
      return if application_base_url.nil?

      uri = URI.parse(application_base_url)
      local = %w[localhost 127.0.0.1 ::1 [::1]].include?(uri.host)
      scheme_valid = uri.scheme == "https" || (uri.scheme == "http" && local && !Rails.env.production?)
      unless uri.host.present? && scheme_valid && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && !application_base_url.match?(/[\x00-\x20\x7f]/)
        raise ConfigurationError, "application_base_url must be a trusted absolute HTTPS engine URL"
      end
    rescue URI::InvalidURIError
      raise ConfigurationError, "application_base_url is invalid"
    end
  end
end
