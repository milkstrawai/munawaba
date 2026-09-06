require "test_helper"
require "pg"

class NotificationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  WEBHOOK = "https://hooks.slack.com/services/TEAM/CHANNEL/concurrency-test".freeze

  setup do
    @original = ActiveRecord::Base.connection_db_config.configuration_hash
    @database = "munawaba_delivery_concurrency_#{SecureRandom.hex(5)}"
    ActiveRecord::Base.connection.create_database(@database)
    ActiveRecord::Base.establish_connection(@original.merge(database: @database))
    ActiveRecord::MigrationContext.new(File.expand_path("../../db/migrate", __dir__)).migrate
    @switch = Munawaba.config.notifications_enabled
    Munawaba.config.notifications_enabled = true
    @now = Time.current
    @schedule = Munawaba::Schedule.create!(name: "Delivery concurrency", cadence: "one_week", time_zone: "UTC",
                                           anchor_local_date: @now.to_date, anchor_local_seconds: 0, slack_webhook_url: WEBHOOK, slack_webhook_configured_at: @now, slack_enabled: true)
    configuration = @original.merge(database: @database).slice(:host, :port, :username, :password, :database)
    @other = PG.connect(host: configuration[:host], port: configuration[:port], user: configuration[:username],
                        password: configuration[:password], dbname: configuration[:database])
  end

  teardown do
    @other&.close
    Munawaba.config.notifications_enabled = @switch
    ActiveRecord::Base.connection_pool.disconnect!
    ActiveRecord::Base.establish_connection(@original)
    ActiveRecord::Base.connection.drop_database(@database)
  end

  test "final authorization bypasses a cached notification epoch after an independent commit" do
    row = claimed
    request = stub_request(:post, WEBHOOK).to_return(status: 200)
    Munawaba::Slack::Renderer.stubs(:call).with do |_arguments|
      @other.exec_params("UPDATE munawaba_schedules SET notification_revision=notification_revision+1 WHERE id=$1",
                         [@schedule.id])
      true
    end.returns({ text: "test" })
    ActiveRecord::Base.cache { Munawaba::Notifications::Deliver.call(row.id, row.claim_token) }
    assert_equal "stale", row.reload.status
    assert_equal "notification_changed", row.last_error_code
    assert_equal 0, row.attempt_count
    assert_not_requested request
  end

  test "final authorization bypasses a cached shift assignment after an independent commit" do
    person = Munawaba::Person.create!(name: "Current", email: "current@example.org")
    boundary = Time.utc(@now.year, @now.month, @now.day)
    @schedule.update!(state: "active", first_activated_at: boundary, coverage_revision: 1, coverage_start_boundary: 0,
                      coverage_starts_at: boundary, generated_through_boundary: 0, rotation_effective_boundary: 0)
    shift = Munawaba::Shift.create!(schedule: @schedule, base_person: person, effective_person: person,
                                    coverage_revision: 1, boundary_index: 0, starts_at: boundary, ends_at: boundary + 1.week, generated_at: @now)
    row = claimed(kind: "shift_start", shift_id: shift.id, coverage_revision: 1, assignment_version: 1,
                  timing_version: 1)
    request = stub_request(:post, WEBHOOK).to_return(status: 200)
    Munawaba::Slack::Renderer.stubs(:call).with do |_arguments|
      @other.exec_params("UPDATE munawaba_shifts SET assignment_version=assignment_version+1 WHERE id=$1", [shift.id])
      true
    end.returns({ text: "test" })
    ActiveRecord::Base.cache { Munawaba::Notifications::Deliver.call(row.id, row.claim_token) }
    assert_equal "stale", row.reload.status
    assert_equal "assignment_changed", row.last_error_code
    assert_equal 0, row.attempt_count
    assert_not_requested request
  end

  private

  def claimed(**attributes)
    Munawaba::NotificationDelivery.create!(**{ schedule: @schedule, kind: "test", status: "enqueued",
                                               event_key: SecureRandom.uuid, notification_revision: 0, context: { "schema_version" => 1 }, due_at: @now, expires_at: @now + 10.minutes, claim_token: SecureRandom.uuid, enqueued_at: @now, lease_expires_at: @now + 30.minutes }.merge(attributes))
  end
end
