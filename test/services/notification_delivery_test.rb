require "test_helper"

class NotificationDeliveryTest < ActiveSupport::TestCase
  WEBHOOK = "https://hooks.slack.com/services/TDEMO/BDEMO/dummysecret".freeze

  setup do
    travel_to Time.utc(2026, 9, 5, 12)
    @settings = Munawaba::Configuration::ATTRIBUTES.to_h { |key| [key, Munawaba.config.public_send(key)] }
    Munawaba.config.notifications_enabled = true
    @schedule = Munawaba::Schedule.create!(name: "Delivery test", cadence: "one_week", time_zone: "UTC",
                                           anchor_local_date: Date.today, anchor_local_seconds: 0)
    result = Munawaba::Integrations.call(operation: :update, schedule: @schedule,
                                         attributes: { slack_webhook_url: WEBHOOK, slack_enabled: true }, actor: actor)
    assert result.success?, result.errors.inspect
    @schedule.reload
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  teardown do
    @settings.each { |key, value| Munawaba.config.public_send("#{key}=", value) }
    travel_back
  end

  def intent
    result = Munawaba::Integrations.call(operation: :test, schedule: @schedule, actor: actor)
    assert result.success?, result.errors.inspect
    @schedule.notification_deliveries.order(:id).last
  end

  def claim(row = intent)
    Munawaba::Notifications::Dispatcher.call
    row.reload
    assert_equal "enqueued", row.status
    row
  end

  def deliver(row)
    Munawaba::Notifications::Deliver.call(row.id, row.claim_token)
    row.reload
  end

  test "any complete 2xx delivers once and duplicate jobs cannot authorize another request" do
    row = claim
    token = row.claim_token
    request = stub_request(:post, WEBHOOK).to_return(status: 204, body: "")
    deliver(row)
    assert_equal "delivered", row.status
    assert_equal 204, row.last_http_status
    assert_equal 1, row.attempt_count
    assert_nil row.claim_token
    assert_nil row.next_attempt_at
    Munawaba::Notifications::Deliver.call(row.id, token)
    assert_requested request, times: 1
  end

  test "redirect permanent client error and unexpected status are terminal with safe codes" do
    [[302, "redirect_rejected"], [403, "slack_rejected"], [418, "slack_rejected"]].each do |code, expected|
      row = claim
      stub_request(:post, WEBHOOK).to_return(status: code, headers: { "Location" => "https://capture.invalid/private" },
                                             body: "private-response")
      deliver(row)
      assert_equal "failed", row.status
      assert_equal expected, row.last_error_code
      assert_equal code, row.last_http_status
      refute_includes row.attributes.to_json, "private-response"
    end
    assert_not_requested :any, /capture.invalid/
  end

  test "429 honors Retry-After and excessive retry delay is terminal" do
    row = claim
    stub_request(:post, WEBHOOK).to_return(status: 429, headers: { "Retry-After" => "120" })
    deliver(row)
    assert_equal "pending", row.status
    assert_operator row.next_attempt_at, :>=, Time.current + 120
    assert_nil row.enqueued_at
    assert_nil row.processing_at
    assert_nil row.claim_token
    row = claim(intent)
    stub_request(:post, WEBHOOK).to_return(status: 429, headers: { "Retry-After" => "3601" })
    deliver(row)
    assert_equal "failed", row.status
    assert_equal "retry_after_out_of_bounds", row.last_error_code
  end

  test "timeout after possible transmission is sticky until a recorded success" do
    row = claim
    stub_request(:post, WEBHOOK).to_raise(Net::ReadTimeout)
    deliver(row)
    assert_equal "pending", row.status
    assert_equal "delivery_outcome_unknown", row.last_error_code
    travel_to(row.next_attempt_at + 1)
    claim(row)
    stub_request(:post, WEBHOOK).to_return(status: 503)
    deliver(row)
    assert_equal "delivery_outcome_unknown", row.last_error_code
    travel_to(row.next_attempt_at + 1)
    claim(row)
    stub_request(:post, WEBHOOK).to_return(status: 201)
    deliver(row)
    assert_equal "delivered", row.status
    assert_nil row.last_error_code
    assert_equal 3, row.attempt_count
  end

  test "exact retry budget fails and expiration never grows" do
    row = claim
    row.update_columns(attempt_count: Munawaba::Defaults::NOTIFICATION_MAX_ATTEMPTS - 1)
    expires = row.expires_at
    stub_request(:post, WEBHOOK).to_return(status: 500)
    deliver(row)
    assert_equal "failed", row.status
    assert_equal "retry_exhausted", row.last_error_code
    assert_equal expires, row.expires_at
  end

  test "global switch false nil and exception return claims without attempts" do
    [false, -> { nil }, -> { raise "secret switch failure" }].each do |switch|
      Munawaba.config.notifications_enabled = true
      row = claim
      Munawaba.config.notifications_enabled = switch
      deliver(row)
      assert_equal "pending", row.status
      assert_equal 0, row.attempt_count
      assert_nil row.claim_token
      assert_equal 0, Munawaba::Notifications::Dispatcher.call
    end
    assert_not_requested :post, WEBHOOK
  end

  test "final switch and notification epoch are rechecked after rendering" do
    row = claim
    Munawaba::Slack::Renderer.stubs(:call).with { |_args|
      Munawaba.config.notifications_enabled = false
      true
    }.returns({ text: "test" })
    deliver(row)
    assert_equal "pending", row.status
    assert_equal 0, row.attempt_count
    assert_not_requested :post, WEBHOOK
  end

  test "invalid persisted context becomes stale before rendering or decryption" do
    row = claim
    row.update_columns(context: { "schema_version" => 1, "webhook" => "forbidden" })
    Munawaba::Slack::Renderer.expects(:call).never
    deliver(row)
    assert_equal "stale", row.status
    assert_equal "invalid_delivery_context", row.last_error_code
    assert_equal 0, row.attempt_count
  end

  test "expiration sweeper uses bounded batches and no expired delivery reaches transport" do
    rows = (Munawaba::Defaults::NOTIFICATION_BATCH_SIZE + 1).times.map { intent }
    travel 11.minutes
    Munawaba::Notifications::Dispatcher.call
    assert_equal(Munawaba::Defaults::NOTIFICATION_BATCH_SIZE, rows.count { |row| row.reload.status == "stale" })
    leftover = rows.find { |row| row.status == "enqueued" }
    deliver(leftover) if leftover
    assert(rows.all? { |row| %w[stale pending].include?(row.reload.status) })
    assert_not_requested :post, WEBHOOK
  end

  test "expired enqueue lease consumes no attempt and old job token is inert" do
    row = claim
    old_token = row.claim_token
    row.update_columns(lease_expires_at: Time.current - 1)
    Munawaba::Notifications::ReclaimExpiredLeases.call
    assert_equal "pending", row.reload.status
    assert_equal 0, row.attempt_count
    assert_nil row.last_error_code
    Munawaba::Notifications::Deliver.call(row.id, old_token)
    assert_not_requested :post, WEBHOOK
  end

  test "expired processing lease records unknown and rejects late completion" do
    row = claim
    token = row.claim_token
    row.update!(status: "processing", processing_at: Time.current - 3.minutes, enqueued_at: Time.current - 4.minutes,
                lease_expires_at: Time.current - 1, attempt_count: 1, last_attempt_at: Time.current - 3.minutes)
    Munawaba::Notifications::ReclaimExpiredLeases.call
    assert_equal "pending", row.reload.status
    assert_equal "delivery_outcome_unknown", row.last_error_code
    assert_equal 1, row.attempt_count
    Munawaba::Notifications::Deliver.complete(row.id, token,
                                              Munawaba::Slack::Client::Result.new(status: :delivered, http_status: 200))
    assert_equal "pending", row.reload.status
  end

  test "domain integration removal during HTTP makes a retry canceled" do
    row = claim
    stub_request(:post, WEBHOOK).to_return do
      result = Munawaba::Integrations.call(operation: :remove, schedule: @schedule, actor: actor)
      assert result.success?, result.errors.inspect
      { status: 503 }
    end
    deliver(row)
    assert_equal "canceled", row.status
    assert_equal "integration_disabled", row.last_error_code
  end

  test "unsuccessful queue enqueue resets the token and lease" do
    row = intent
    Munawaba::DeliverNotificationJob.stubs(:perform_later).returns(false)
    Munawaba::Notifications::Dispatcher.call
    assert_equal "pending", row.reload.status
    assert_nil row.claim_token
    assert_nil row.enqueued_at
    assert_equal 0, row.attempt_count
  end

  test "manual retry creates one current-epoch successor and preserves predecessor and expiration" do
    row = claim
    stub_request(:post, WEBHOOK).to_return(status: 403)
    deliver(row)
    failed_attributes = row.attributes
    update = Munawaba::Integrations.call(operation: :update, schedule: @schedule,
                                         attributes: { slack_webhook_url: WEBHOOK.sub("dummysecret", "replacement") }, actor: actor)
    assert update.success?, update.errors.inspect
    result = Munawaba::Notifications::RetryFailed.call(delivery: row, actor: actor)
    assert result.success?, result.errors.inspect
    assert_equal row.id, result.record.retry_of_delivery_id
    assert_equal row.expires_at, result.record.expires_at
    assert_equal @schedule.reload.notification_revision, result.record.notification_revision
    assert_equal failed_attributes, row.reload.attributes
    assert_equal 422, Munawaba::Notifications::RetryFailed.call(delivery: row, actor: actor).status
  end

  test "unknown manual retry requires explicit duplicate risk acknowledgment" do
    row = claim
    row.update_columns(attempt_count: Munawaba::Defaults::NOTIFICATION_MAX_ATTEMPTS - 1)
    stub_request(:post, WEBHOOK).to_raise(Net::ReadTimeout)
    deliver(row)
    assert_equal "failed", row.status
    assert_equal 422, Munawaba::Notifications::RetryFailed.call(delivery: row, actor: actor).status
    result = Munawaba::Notifications::RetryFailed.call(delivery: row, actor: actor, acknowledge_duplicate: true)
    assert result.success?, result.errors.inspect
  end

  test "test intent and retry work without an actor" do
    result = Munawaba::Integrations.call(operation: :test, schedule: @schedule)
    assert result.success?, result.errors.inspect
    row = @schedule.notification_deliveries.order(:id).last
    row.update!(status: "failed", next_attempt_at: nil, last_error_code: "server_error")

    retried = Munawaba::Notifications::RetryFailed.call(delivery: row)
    assert retried.success?, retried.errors.inspect
    assert_nil Munawaba::AuditEvent.order(:id).last.actor_id
  end

  test "integration failures roll back inside an already open host transaction" do
    Munawaba::Audit::Recorder.stubs(:record!).raises(ActiveRecord::RecordInvalid.new(Munawaba::AuditEvent.new))
    original = @schedule.attributes
    count = Munawaba::NotificationDelivery.count
    Munawaba::Schedule.transaction do
      result = Munawaba::Integrations.call(operation: :update, schedule: @schedule,
                                           attributes: { slack_webhook_url: WEBHOOK.sub("dummysecret", "newsecret") }, actor: nil)
      assert_equal 422, result.status
      assert_equal original, @schedule.reload.attributes
      result = Munawaba::Integrations.call(operation: :remove, schedule: @schedule, actor: nil)
      assert_equal 422, result.status
      assert_equal original, @schedule.reload.attributes
      result = Munawaba::Integrations.call(operation: :test, schedule: @schedule, actor: nil)
      assert_equal 422, result.status
      assert_equal count, Munawaba::NotificationDelivery.count
    end
  end

  test "settings reject invalid lead time and never expose the saved webhook" do
    [59, 2_592_001].each do |value|
      result = Munawaba::Integrations.call(operation: :update, schedule: @schedule, attributes: { advance_notice_seconds: value },
                                           actor: actor)
      assert_equal 422, result.status
    end
    [60, 2_592_000].each do |value|
      result = Munawaba::Integrations.call(operation: :update, schedule: @schedule, attributes: { advance_notice_seconds: value },
                                           actor: actor)
      assert result.success?, result.errors.inspect
    end
    refute_includes @schedule.reload.inspect, WEBHOOK
    ciphertext = Munawaba::Schedule.connection.select_value("SELECT slack_webhook_url FROM munawaba_schedules WHERE id = #{@schedule.id}")
    refute_includes ciphertext, "dummysecret"
    refute_includes @schedule.audit_events.pluck(:metadata).to_json, "dummysecret"
  end

  test "invalid webhook validation leaves settings and pending deliveries unchanged" do
    row = intent
    original_schedule = @schedule.attributes
    original_delivery = row.attributes
    webhook = "https://untrusted.example/services/T/B/PrivateWebhookSecret"
    assert_no_difference ["Munawaba::NotificationDelivery.count", "Munawaba::AuditEvent.count"] do
      result = Munawaba::Integrations.call(operation: :update, schedule: @schedule,
                                           attributes: { slack_webhook_url: webhook, notify_advance: false })
      assert_equal 422, result.status
      assert_includes result.record.errors[:slack_webhook_url], "must be an allowed Slack incoming webhook"
      refute_includes result.errors.join, "PrivateWebhookSecret"
    end
    assert_equal original_schedule, @schedule.reload.attributes
    assert_equal original_delivery, row.reload.attributes
  end

  test "missing encryption credentials return validation errors before saving a webhook" do
    schedule = Munawaba::Schedule.create!(name: "Missing encryption", cadence: "one_week", time_zone: "UTC",
                                          anchor_local_date: Date.today, anchor_local_seconds: 0)
    original = schedule.attributes
    configuration = ActiveRecord::Encryption.config
    %i[primary_key key_derivation_salt].each do |setting|
      previous = configuration.public_send(setting)
      begin
        configuration.public_send("#{setting}=", nil)
        assert_no_difference ["Munawaba::NotificationDelivery.count", "Munawaba::AuditEvent.count"] do
          result = Munawaba::Integrations.call(operation: :update, schedule: schedule,
                                               attributes: { slack_webhook_url: WEBHOOK, slack_enabled: true })
          assert_equal 422, result.status
          assert_includes result.record.errors[:slack_webhook_url], "requires host Active Record Encryption keys"
          refute_includes result.errors.join, "dummysecret"
        end
        assert_equal original, schedule.reload.attributes
      ensure
        configuration.public_send("#{setting}=", previous)
      end
    end
  end

  test "all integration actions reject a stale form before changing settings or notifications" do
    original = @schedule.attributes
    %i[update remove test].each do |operation|
      assert_no_difference ["Munawaba::NotificationDelivery.count", "Munawaba::AuditEvent.count"] do
        result = Munawaba::Integrations.call(operation: operation, schedule: @schedule,
                                             attributes: { lock_version: @schedule.lock_version - 1, slack_enabled: false })
        assert_equal 409, result.status
        ending = operation == :update ? "Review and save again." : "Review them again."
        assert_equal ["Integration settings changed. #{ending}"], result.errors
      end
      assert_equal original, @schedule.reload.attributes
    end
  end

  test "saving an unchanged integration preserves its epoch and history" do
    original = @schedule.attributes
    assert_no_difference ["Munawaba::NotificationDelivery.count", "Munawaba::AuditEvent.count"] do
      result = Munawaba::Integrations.call(operation: :update, schedule: @schedule,
                                           attributes: { slack_webhook_url: "", lock_version: @schedule.lock_version })
      assert_equal 303, result.status
    end
    assert_equal original, @schedule.reload.attributes
  end

  test "unconfigured integration actions retain their specific errors" do
    assert Munawaba::Integrations.call(operation: :remove, schedule: @schedule).success?
    assert_no_difference ["Munawaba::NotificationDelivery.count", "Munawaba::AuditEvent.count"] do
      removed = Munawaba::Integrations.call(operation: :remove, schedule: @schedule)
      assert_equal 422, removed.status
      assert_equal ["No webhook is configured."], removed.errors
      tested = Munawaba::Integrations.call(operation: :test, schedule: @schedule)
      assert_equal 422, tested.status
      assert_equal ["Configure and enable Slack first."], tested.errors
    end
  end

  test "job arguments contain only delivery ID and random claim token" do
    row = claim
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |entry| entry[:job] == Munawaba::DeliverNotificationJob }
    assert_equal [row.id, row.claim_token], job[:args]
    refute_includes job[:args].to_json, "dummysecret"
  end

  test "delivery job fails closed inside a host transaction before authorizing HTTP" do
    row = claim
    assert_raises(Munawaba::Error) { Munawaba::DeliverNotificationJob.perform_now(row.id, row.claim_token) }
    assert_equal "enqueued", row.reload.status
    assert_equal 0, row.attempt_count
    assert_not_requested :post, WEBHOOK
  end
end
