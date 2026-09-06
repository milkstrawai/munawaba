# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"
require "active_record"
require "active_job"
require "action_controller/railtie"
require "tzinfo"
require_relative "munawaba/version"

module Munawaba
  class Error < StandardError; end
  class ConfigurationError < Error; end

  def self.configuration
    @configuration ||= Configuration.new
  end
  class << self
    alias config configuration
  end

  def self.configure
    yield configuration
  end

  def self.signal(event, **values)
    ActiveSupport::Notifications.instrument("#{event}.munawaba", values)
  end
end

require_relative "munawaba/defaults"
require_relative "munawaba/configuration"
require_relative "munawaba/engine"
