# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"

module Munawaba
  module Slack
    class Client
      Result = Struct.new(:status, :http_status, :error_code, :retry_after, :unknown, keyword_init: true)
      class DeadlineExceeded < StandardError; end
      class ResponseTooLarge < StandardError; end
      MAX_RESPONSE_BYTES = 16_384

      def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def self.call(webhook:, payload:, deadline:)
        new.call(webhook: webhook, payload: payload, deadline: deadline)
      end

      def call(webhook:, payload:, deadline:)
        transmitted = false
        http = nil
        uri = WebhookValidator.validate!(webhook)
        remaining = deadline - self.class.monotonic
        raise DeadlineExceeded if remaining <= 0

        http = Net::HTTP.new(uri.host, uri.port, nil)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.max_retries = 0
        http.open_timeout = [Defaults::SLACK_OPEN_TIMEOUT.to_f, remaining].min
        http.read_timeout = [Defaults::SLACK_READ_TIMEOUT.to_f, remaining].min
        http.write_timeout = [Defaults::SLACK_WRITE_TIMEOUT.to_f, remaining].min
        request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
        request.body = JSON.generate(payload)
        result = nil
        Timeout.timeout(remaining, DeadlineExceeded) do
          http.start do
            budget = deadline - self.class.monotonic
            raise DeadlineExceeded if budget <= 0

            http.read_timeout = [Defaults::SLACK_READ_TIMEOUT.to_f, budget].min
            http.write_timeout = [Defaults::SLACK_WRITE_TIMEOUT.to_f, budget].min
            transmitted = true
            http.request(request) do |response|
              bytes = 0
              response.read_body do |chunk|
                bytes += chunk.bytesize
                raise ResponseTooLarge if bytes > MAX_RESPONSE_BYTES
                raise DeadlineExceeded if self.class.monotonic >= deadline
              end
              raise DeadlineExceeded if self.class.monotonic >= deadline

              code = response.code.to_i
              retry_after = response["Retry-After"].to_s
              seconds = retry_after.match?(/\A\d+\z/) ? retry_after.to_i : nil
              result = classify(code, seconds)
            end
          end
        end
        result
      rescue WebhookValidator::Invalid, JSON::GeneratorError
        Result.new(status: :failed, error_code: "invalid_webhook", unknown: false)
      rescue OpenSSL::SSL::SSLError
        Result.new(status: :failed, error_code: transmitted ? "delivery_outcome_unknown" : "tls_failure",
                   unknown: transmitted)
      rescue DeadlineExceeded, Timeout::Error
        Result.new(status: :retry, error_code: transmitted ? "delivery_outcome_unknown" : "network_timeout",
                   unknown: transmitted)
      rescue SocketError, SystemCallError, IOError, ResponseTooLarge, Net::HTTPBadResponse, Net::ProtocolError
        Result.new(status: :retry, error_code: transmitted ? "delivery_outcome_unknown" : "network_error",
                   unknown: transmitted)
      ensure
        begin
          http.finish if http&.started?
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          # Return fixed error codes, without Slack response bodies or exception messages.
        end
      end

      private

      def classify(code, retry_after)
        case code
        when 200..299
          Result.new(status: :delivered, http_status: code, unknown: false)
        when 300..399
          Result.new(status: :failed, http_status: code, error_code: "redirect_rejected", unknown: false)
        when 429
          if retry_after && retry_after > Defaults::NOTIFICATION_RETRY_AFTER_CAP
            Result.new(status: :failed, http_status: code, error_code: "retry_after_out_of_bounds", unknown: false)
          else
            Result.new(status: :retry, http_status: code, error_code: "rate_limited",
                       retry_after: retry_after&.positive? ? retry_after : nil, unknown: false)
          end
        when 408, 500..599
          Result.new(status: :retry, http_status: code, error_code: "upstream_unavailable", unknown: false)
        else
          Result.new(status: :failed, http_status: code, error_code: "slack_rejected", unknown: false)
        end
      end
    end
  end
end
