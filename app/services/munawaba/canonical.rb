# frozen_string_literal: true

require "digest"
require "json"

module Munawaba
  module Canonical
    module_function

    def time(value)
      Time.at(value.to_time.utc.to_r.floor(6)).utc
    end

    def micros(value)
      (value.to_time.utc.to_r * 1_000_000).floor
    end

    def instant(value)
      value&.utc&.iso8601(6)
    end

    def from_micros(value)
      Time.at(Rational(Integer(value), 1_000_000)).utc
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(value))
    end

    def equal?(left, right)
      left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def deep_freeze(value)
      case value
      when Array then value.each { |item| deep_freeze(item) }
      when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      end
      value.freeze
    end
  end
end
