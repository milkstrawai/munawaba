# frozen_string_literal: true

require "test_helper"

class RouteContractTest < ActionDispatch::IntegrationTest
  setup do
    @config = Munawaba.config
    @callbacks = [@config.authenticate, @config.authorize, @config.actor]
    @config.authenticate = ->(_) { true }
    @config.authorize = ->(*) { true }
    @config.actor = ->(_) { actor }
    @person = Munawaba::Person.create!(name: "Route person", email: "route-#{SecureRandom.hex(4)}@example.com")
    @schedule = active_schedule("Route schedule #{SecureRandom.hex(4)}", @person)
    @shift = @schedule.shifts.live.order(:starts_at).first
    @delivery = Munawaba::NotificationDelivery.create!(schedule: @schedule, kind: "test", status: "failed",
                                                       event_key: SecureRandom.uuid, notification_revision: @schedule.notification_revision,
                                                       context: { "schema_version" => 1 }, due_at: Time.current - 1.minute, expires_at: Time.current + 1.hour,
                                                       attempt_count: 1, last_attempt_at: Time.current - 30.seconds, last_error_code: "delivery_outcome_unknown")
  end

  teardown do
    @config.authenticate, @config.authorize, @config.actor = @callbacks
  end

  test "every HTML route authenticates then authorizes its exact documented capability and record once" do
    authenticated, authorized, sequence = [], [], []
    @config.authenticate = ->(controller) { authenticated << controller; sequence << :authenticate; true }
    @config.authorize = ->(controller, capability, record) {
      authorized << [controller, capability, record]; sequence << :authorize; false
    }
    @config.actor = ->(_) { flunk "Denied requests must not resolve a mutation actor" }
    Munawaba::Commands.expects(:call).never
    Munawaba::Commands.expects(:preview).never
    Munawaba::Integrations.expects(:call).never
    Munawaba::Notifications::RetryFailed.expects(:call).never
    matrix = route_matrix
    matrix += matrix.select { |method,|
      method == :get
    }.map { |_method, path, capability, record| [:head, path, capability, record] }
    %w[people schedules].each do |resource|
      record = resource == "people" ? @person : @schedule
      capability = resource == "people" ? :manage_people : :manage_schedules
      matrix << [:put, "/#{resource}/#{record.id}", capability, record]
    end
    matrix += [[:put, "/schedules/#{@schedule.id}/rotation", :manage_rotations, @schedule],
               [:put, "/schedules/#{@schedule.id}/slack_integration", :manage_integrations, @schedule],
               [:put, "/shifts/#{@shift.id}/override", :override_shifts, @shift]]
    assert_equal 67, matrix.length
    matrix.each do |method, path, capability, record|
      authenticated.clear
      authorized.clear
      sequence.clear
      public_send(method, "/on-call#{path}")
      assert_response :forbidden, "#{method.upcase} #{path}"
      assert_equal [:authenticate, :authorize], sequence, path
      assert_equal [[authenticated.fetch(0), capability, record]], authorized, path
      assert_equal 1, authenticated.length, path
      assert_empty response.body, path
    end
    sequence.clear
    get "/on-call/overview.json"
    assert_response :forbidden
    assert_equal [:authenticate, :authorize], sequence
  end

  test "populated delivery history displays the sticky unknown marker and explicit duplicate acknowledgment" do
    get "/on-call/notification_deliveries"
    assert_response :ok
    assert_select "tbody tr", count: 1
    assert_select ".mn-conflict", /Unknown outcome/
    assert_select "input[name='acknowledge_duplicate'][required]"
    assert_select "input[value='Retry failed delivery']"
    refute_includes response.body, "NoMethodError"
  end

  test "failed retry does not disclose global history under a delivery-scoped grant" do
    other = @delivery.dup
    other.event_key = SecureRandom.uuid
    other.last_error_code = "rate_limited"
    other.save!
    calls = []
    @config.authorize = ->(_controller, capability, record) { calls << [capability, record]; record == @delivery }
    Munawaba::Notifications::RetryFailed.stubs(:call).returns(Munawaba::Result.new(status: 422, record: @delivery,
                                                                                   errors: ["Acknowledge the possible duplicate before retrying."]))
    post "/on-call/notification_deliveries/#{@delivery.id}/retry"
    assert_response :unprocessable_entity
    assert_equal [[:manage_integrations, @delivery]], calls
    assert_select "tbody tr", count: 1
    assert_select ".mn-conflict", /Unknown outcome/
    refute_includes response.body, "rate_limited"
  end

  test "malformed request shapes return 400 instead of controller exceptions or writes" do
    cases = [
      [:post, "/people", {}], [:post, "/people", { person: "wrong shape" }],
      [:post, "/schedules", { schedule: "wrong shape" }],
      [:patch, "/schedules/#{@schedule.id}/slack_integration", { integration: "wrong shape" }],
      [:post, "/schedules/#{@schedule.id}/rotation/preview", { person_ids: @person.id.to_s }],
      [:patch, "/schedules/#{@schedule.id}/rotation", { person_ids: [{ unexpected: @person.id }] }],
      [:post, "/schedules/#{@schedule.id}/preview_resume", { edit_order: "add", person_ids: { unexpected: @person.id } }],
      [:get, "/calendar", { date: [Date.current.iso8601] }],
      [:get, "/activity", { event_type: { unexpected: "person.created" } }],
      [:get, "/notification_deliveries", { status: { unexpected: "failed" } }],
      [:get, "/people", { after: { unexpected: "cursor" } }]
    ]
    writes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, event|
      writes << event[:sql] if event[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i)
    end
    cases.each do |method, path, attributes|
      public_send(method, "/on-call#{path}", params: attributes)
      assert_response :bad_request, "#{method.upcase} #{path}"
    end
    assert_empty writes
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "overview executes five selects independent of schedule count" do
    get "/on-call"
    assert_response :ok
    assert_equal 5, overview_selects.length
    5.times do |number|
      person = Munawaba::Person.create!(name: "Overview person #{number}",
                                        email: "overview#{number}-#{SecureRandom.hex(3)}@example.com")
      active_schedule("Overview #{number} #{SecureRandom.hex(3)}", person)
    end
    queries = overview_selects
    assert_equal 5, queries.length, queries.join("\n")
    refute(queries.any? { |sql| sql.match?(/munawaba_(audit_events|notification_deliveries)/) })
  end

  test "full page engine navigation isolates host Turbo and includes host CSP nonces" do
    environment = Rails.application.env_config
    key = "action_dispatch.content_security_policy_nonce_generator"
    previous = environment[key]
    environment[key] = ->(_) { "ui-review-nonce" }
    get "/on-call"
    assert_response :ok
    assert_select "meta[name='turbo-visit-control'][content='reload']"
    assert_select ".mn-app[data-turbo='false']"
    assert_select "script[src$='dashboard.js'][nonce='ui-review-nonce'][defer]"
    assert_select "link[href$='dashboard.css'][nonce='ui-review-nonce']"
    assert_select "script:not([src])", count: 0
  ensure
    environment[key] = previous if environment
  end

  private

  def active_schedule(name, person)
    schedule = Munawaba::Schedule.create!(name: name, cadence: "one_week", time_zone: "UTC",
                                          anchor_local_date: Date.current - 1, anchor_local_seconds: 0)
    Munawaba::ScheduleMembership.create!(schedule: schedule, person: person, position: 0)
    preview = Munawaba::Commands.preview(operation: :activate, subject: schedule, actor: actor)
    result = Munawaba::Commands.call(operation: :activate, subject: schedule, actor: actor,
                                     token: preview.preview.token)
    assert result.success?, result.errors.inspect
    schedule.reload
  end

  def overview_selects
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, event|
      queries << event[:sql] if event[:name] != "SCHEMA" && event[:sql].match?(/\A\s*(SELECT|WITH)\b/i) && event[:sql].include?("munawaba_")
    end
    get "/on-call"
    assert_response :ok
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def route_matrix
    person = "/people/#{@person.id}"
    schedule = "/schedules/#{@schedule.id}"
    shift = "/shifts/#{@shift.id}"
    [[:get, "", :read, :overview], [:get, "/overview", :read, :overview], [:get, "/calendar", :read, :calendar],
     [:get, "/people", :read, Munawaba::Person], [:get, "/people/new", :manage_people, Munawaba::Person],
     [:post, "/people", :manage_people, Munawaba::Person], [:get, person, :read, @person],
     [:get, "#{person}/edit", :manage_people, @person], [:patch, person, :manage_people, @person],
     [:get, "#{person}/deactivation", :manage_people, @person], [:patch, "#{person}/deactivate", :manage_people, @person],
     [:patch, "#{person}/reactivate", :manage_people, @person],
     [:get, "/schedules", :read, Munawaba::Schedule], [:get, "/schedules/new", :manage_schedules, Munawaba::Schedule],
     [:post, "/schedules", :manage_schedules, Munawaba::Schedule], [:get, schedule, :read, @schedule],
     [:get, "#{schedule}/edit", :manage_schedules, @schedule], [:patch, schedule, :manage_schedules, @schedule],
     *%w[preview_activation activate pause preview_resume resume cancel_scheduled].map { |action|
       [:post, "#{schedule}/#{action}", :manage_schedules, @schedule]
     },
     [:get, "#{schedule}/rotation/edit", :manage_rotations, @schedule], [:post, "#{schedule}/rotation/preview", :manage_rotations, @schedule],
     [:patch, "#{schedule}/rotation", :manage_rotations, @schedule], [:get, "#{schedule}/slack_integration/edit", :manage_integrations, @schedule],
     [:patch, "#{schedule}/slack_integration", :manage_integrations, @schedule], [:post, "#{schedule}/slack_integration/test", :manage_integrations, @schedule],
     [:delete, "#{schedule}/slack_integration/remove", :manage_integrations, @schedule], [:get, shift, :read, @shift],
     [:get, "#{shift}/override/new", :override_shifts, @shift], [:post, "#{shift}/override/preview", :override_shifts, @shift],
     [:post, "#{shift}/override", :override_shifts, @shift], [:get, "#{shift}/override/edit", :override_shifts, @shift],
     [:patch, "#{shift}/override", :override_shifts, @shift], [:patch, "#{shift}/override/revoke", :override_shifts, @shift],
     [:patch, "#{shift}/override/restore", :override_shifts, @shift], [:get, "/activity", :view_audit, :activity],
     [:get, "/notification_deliveries", :manage_integrations, :notification_deliveries],
     [:post, "/notification_deliveries/#{@delivery.id}/retry", :manage_integrations, @delivery], [:patch, "/theme", :read, :theme]]
  end
end
