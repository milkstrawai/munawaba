require_relative "boot"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "munawaba"

module MunawabaDummy
  class Application < Rails::Application
    config.load_defaults "#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}"
    config.eager_load = false
    config.enable_reloading = !Rails.env.test?
    config.secret_key_base = "munawaba-local-test-host-secret-key-base-only-" * 3
    config.active_record.schema_format = :ruby
    config.active_record.dump_schema_after_migration = false
    config.active_job.queue_adapter = :test
    config.hosts.clear
    config.action_controller.allow_forgery_protection = !Rails.env.test?
    config.active_record.encryption.primary_key = "dummy-only-primary-key-32-characters"
    config.active_record.encryption.deterministic_key = "dummy-only-deterministic-key-32-chars"
    config.active_record.encryption.key_derivation_salt = "dummy-only-salt-for-local-testing"
    config.paths["db/migrate"] = [File.expand_path("../../../db/migrate", __dir__)]
    config.logger = ActiveSupport::Logger.new(File::NULL) if Rails.env.test?
  end
end

Munawaba.configure do |config|
  config.authenticate = ->(_controller) { true }
  config.authorize = ->(_controller, _action, _record) { true }
  config.actor = ->(_controller) { { type: "DemoAdmin", id: "1", name: "Demo administrator" } }
  config.application_base_url = "http://localhost:3100/on-call"
  config.notifications_enabled = false
end
