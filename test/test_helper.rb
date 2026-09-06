ENV["RAILS_ENV"] = "test"
require_relative "dummy/config/environment"
ActiveRecord::Migration.verbose = false
paths = [File.expand_path("../db/migrate", __dir__)]
ActiveRecord::MigrationContext.new(paths).migrate
require "rails/test_help"
require "mocha/minitest"
require "webmock/minitest"
WebMock.disable_net_connect!(allow_localhost: true)

class ActiveSupport::TestCase
  self.use_transactional_tests = true

  def actor
    { type: "User", id: "1", name: "Test administrator" }
  end
end
