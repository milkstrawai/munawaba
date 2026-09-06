# frozen_string_literal: true

require "uri"
module Munawaba
  module Slack
    class WebhookValidator
      class Invalid < Munawaba::Error
        def initialize(*) = super("Enter a valid allowed HTTPS Slack webhook")
      end

      def self.validate!(value)
        raise Invalid unless value.is_a?(String) && !value.match?(/[\x00-\x20\x7f]/)

        uri = URI.parse(value)
        raise Invalid unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise Invalid unless Munawaba.config.slack_allowed_hosts.include?(uri.host&.downcase)
        raise Invalid unless uri.path.present? && uri.path != "/" && !uri.path.match?(/%(?:0[0-9a-f]|1[0-9a-f]|7f)/i)

        if %w[hooks.slack.com hooks.slack-gov.com].include?(uri.host.downcase)
          raise Invalid unless uri.path.match?(%r{\A/services/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\z})
        end
        uri
      rescue URI::InvalidURIError
        raise Invalid
      end

      def self.valid?(value)
        validate!(value)
        true
      rescue Invalid
        false
      end
    end
  end
end
