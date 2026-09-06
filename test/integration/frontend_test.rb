# frozen_string_literal: true

require "test_helper"

class FrontendTest < ActionDispatch::IntegrationTest
  setup do
    @config = Munawaba.config
    @callbacks = [@config.authenticate, @config.authorize, @config.actor]
    @config.authenticate = ->(_) { true }
    @config.authorize = ->(*) { true }
    @config.actor = ->(_) { actor }
    @person = Munawaba::Person.create!(name: "Amal Rahman", email: "amal-#{SecureRandom.hex(4)}@example.com")
    @other = Munawaba::Person.create!(name: "Omar Nasser", email: "omar-#{SecureRandom.hex(4)}@example.com")
    @schedule = Munawaba::Schedule.create!(name: "Platform #{SecureRandom.hex(4)}", cadence: "one_week",
                                           time_zone: "UTC", anchor_local_date: Date.current - 1, anchor_local_seconds: 9 * 3600)
  end

  teardown do
    @config.authenticate, @config.authorize, @config.actor = @callbacks
  end

  test "registration and schedule setup work through forms" do
    get "/on-call/people/new"
    assert_response :ok
    assert_select "form[method=post] input[name='person[name]']"
    post "/on-call/people", params: { person: { name: "Leila", email: "leila-#{SecureRandom.hex(4)}@example.com" } }
    assert_response :see_other
    follow_redirect!
    assert_select "h1", "Leila"
    post "/on-call/schedules",
         params: { schedule: { name: "New schedule #{SecureRandom.hex(4)}", cadence: "calendar_month",
                               time_zone: "Europe/London", anchor_local_date: "2026-09-30", anchor_local_time: "09:30" } }
    assert_response :see_other
    follow_redirect!
    assert_response :ok
    assert_select ".mn-badge", "Draft"
  end

  test "rotation activation override pause and resume use preview envelopes" do
    save_rotation([@person.id, @other.id])
    post "/on-call/schedules/#{@schedule.id}/preview_activation"
    assert_response :ok
    assert_select "h1", "Review activation"
    assert_no_difference("Munawaba::Shift.count") { get "/on-call/calendar" }
    post "/on-call/schedules/#{@schedule.id}/preview_activation"
    token = proposal_token
    post "/on-call/schedules/#{@schedule.id}/activate", params: { proposal_token: token }
    assert_response :see_other
    assert_equal "active", @schedule.reload.state
    shift = @schedule.shifts.live.current.first
    get "/on-call/shifts/#{shift.id}"
    assert_response :ok
    assert_select "h1", @schedule.name
    post "/on-call/shifts/#{shift.id}/override/preview",
         params: { person_id: @other.id, reason: "Coverage & support <safe>", operation: "apply" }
    assert_response :ok
    token = proposal_token
    post "/on-call/shifts/#{shift.id}/override",
         params: { proposal_token: token, person_id: @other.id, reason: "Coverage & support <safe>" }
    assert_response :see_other
    assert_equal @other.id, shift.reload.effective_person_id
    get "/on-call/shifts/#{shift.id}/override/edit"
    assert_response :ok
    assert_select "h1", "Override whole shift"
    assert_select "form[action='/on-call/shifts/#{shift.id}/override/preview'] select[name=person_id]"
    post "/on-call/schedules/#{@schedule.id}/pause", params: { lock_version: @schedule.lock_version }
    assert_response :ok
    token = proposal_token
    post "/on-call/schedules/#{@schedule.id}/pause",
         params: { proposal_token: token, lock_version: @schedule.lock_version }
    assert_response :see_other
    assert_equal "pausing", @schedule.reload.state
    travel_to(shift.ends_at + 1.second) do
      Munawaba::Shifts::NormalizeFutureTiming.call(schedule: @schedule)
      get "/on-call/schedules/#{@schedule.id}"
      assert_response :ok
      assert_select "input[value='Preview resume']"
      boundary = Munawaba::Timing::BoundaryCalculator.new(@schedule).selectable_boundaries(now: Time.current).first.index
      post "/on-call/schedules/#{@schedule.id}/preview_resume",
           params: { boundary_index: boundary, person_ids: [@other.id, @person.id] }
      assert_response :ok
      token = proposal_token
      post "/on-call/schedules/#{@schedule.id}/resume",
           params: { proposal_token: token, boundary_index: boundary, person_ids: [@other.id, @person.id] }
      assert_response :see_other
      assert_equal "scheduled", @schedule.reload.state
    end
  end

  test "all readable pages omit privileged queries and authorize only their route" do
    calls, sql = [], []
    @config.authorize = ->(_controller, capability, record) { calls << [capability, record]; true }
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |_name, _start, _finish, _id, event| sql << event[:sql] }
    ["", "/overview", "/people", "/people/#{@person.id}", "/schedules", "/schedules/#{@schedule.id}", "/calendar",
     "/calendar?view=month"].each do |path|
      calls.clear
      sql.clear
      get "/on-call#{path}"
      assert_response :ok
      assert_equal 1, calls.size
      assert_equal :read, calls.first.first
      refute sql.any? { |query|
        query.match?(/SELECT.*munawaba_(audit_events|notification_deliveries)/i)
      }, sql.join("\n")
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "authentication and authorization fail closed and preserve performed responses" do
    calls = []
    @config.authenticate = nil
    @config.authorize = ->(*) { calls << true; true }
    get "/on-call"
    assert_response :unauthorized
    assert_empty calls
    @config.authenticate = ->(_) { true }
    @config.authorize = nil
    get "/on-call"
    assert_response :forbidden
    @config.authenticate = ->(controller) { controller.redirect_to("/login"); false }
    get "/on-call"
    assert_redirected_to "/login"
  end

  test "privileged destinations use exact capabilities without leaking data" do
    seen = []
    @config.authorize = ->(_controller, action, record) { seen << [action, record]; false }
    { "/activity?person_id=#{@person.id}" => [:view_audit, :activity],
      "/notification_deliveries?schedule_id=#{@schedule.id}" => [:manage_integrations, :notification_deliveries], "/schedules/#{@schedule.id}/slack_integration/edit" => [:manage_integrations, @schedule], "/schedules/#{@schedule.id}/rotation/edit" => [:manage_rotations, @schedule], "/people/#{@person.id}/deactivation" => [:manage_people, @person] }.each do |path, expected|
      seen.clear
      get "/on-call#{path}"
      assert_response :forbidden
      assert_equal [expected], seen
      refute_includes response.body, @schedule.name
    end
  end

  test "validation retains user values and stale rotation refreshes once without mutation" do
    post "/on-call/people", params: { person: { name: "Keep my name", email: "" } }
    assert_response :unprocessable_entity
    assert_select "input[value='Keep my name']"
    assert_select ".mn-error-summary[role=alert]"
    save_rotation([@person.id, @other.id])
    post "/on-call/schedules/#{@schedule.id}/rotation/preview",
         params: { person_ids: [@other.id, @person.id], lock_version: @schedule.reload.lock_version }
    stale = proposal_token
    save_rotation([@person.id])
    assert_no_difference("Munawaba::AuditEvent.count") do
      patch "/on-call/schedules/#{@schedule.id}/rotation",
            params: { person_ids: [@other.id, @person.id], proposal_token: stale }
    end
    assert_response :conflict
    assert_select ".mn-error-summary", /Projected assignments or handoff times changed/
    assert_select "input[name='proposal_token']", count: 1
    assert_select "input[name='person_ids[]'][value='#{@other.id}']"
  end

  test "calendar limits reject invalid input and every read is nonmutating" do
    save_rotation([@person.id])
    assert_no_difference("Munawaba::Shift.count") do
      get "/on-call/calendar", params: { date: (Date.current + 3.years).iso8601 }
      assert_response :unprocessable_entity
      get "/on-call/calendar", params: { date: "bogus" }
      assert_response :unprocessable_entity
      get "/on-call/calendar", params: { date: Date.current.iso8601, until: (Date.current + 5.months).iso8601 }
      assert_response :unprocessable_entity
    end
  end

  test "theme uses PATCH, redirects stay local, and assets use a public manifest" do
    patch "/on-call/theme", params: { theme: "light" }, headers: { "HTTP_REFERER" => "https://evil.example/" }
    assert_response :see_other
    assert_redirected_to "/on-call/"
    get "/on-call"
    assert_select ".mn-app[data-mn-theme=light]"
    @config.authenticate = ->(_) { flunk "Assets must bypass authentication" }
    @config.authorize = ->(*) { flunk "Assets must bypass authorization" }
    get "/on-call/assets/#{Munawaba::VERSION}/dashboard.css"
    assert_response :ok
    assert_match "text/css", response.content_type
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_includes response.headers["Cache-Control"], "immutable"
    ActionController::Base.allow_forgery_protection = true
    get "/on-call/assets/#{Munawaba::VERSION}/dashboard.js"
    assert_response :ok
    assert_match "javascript", response.content_type
    ActionController::Base.allow_forgery_protection = false
    { "logo.png" => "image/png", "inter.woff2" => "font/woff2", "jetbrains-mono.woff2" => "font/woff2" }.each do |filename, type|
      get "/on-call/assets/#{Munawaba::VERSION}/#{filename}"
      assert_response :ok
      assert_equal type, response.media_type
    end
    get "/on-call/assets/unknown/dashboard.css"
    assert_response :not_found
    get "/on-call/assets/#{Munawaba::VERSION}/secret.txt"
    assert_response :not_found
    get "/on-call/assets/#{Munawaba::VERSION}/%2e%2e%2fconfig%2froutes.rb"
    assert_response :not_found
  end

  test "HTML only and mutations require CSRF when protection enabled" do
    get "/on-call/overview.json"
    assert_response :not_acceptable
    Munawaba::ApplicationController.allow_forgery_protection = true
    assert_no_difference("Munawaba::Person.count") { post "/on-call/people", params: { person: { name: "CSRF", email: "csrf@example.com" } } }
    assert_response :unprocessable_entity
  ensure
    Munawaba::ApplicationController.allow_forgery_protection = false
  end

  test "person deactivation previews every schedule and reactivation preserves removed memberships" do
    save_rotation([@person.id, @other.id])
    get "/on-call/people/#{@person.id}/deactivation"
    assert_response :ok
    assert_select "h1", "Review deactivation"
    assert_select "h2", @schedule.name
    token = proposal_token
    patch "/on-call/people/#{@person.id}/deactivate", params: { proposal_token: token }
    assert_response :see_other
    refute @person.reload.active?
    assert_equal [@other.id], @schedule.ordered_person_ids
    patch "/on-call/people/#{@person.id}/reactivate", params: { lock_version: @person.lock_version }
    assert_response :see_other
    assert @person.reload.active?
    assert_equal [@other.id], @schedule.ordered_person_ids
  end

  test "integration HTML never returns webhook secrets on save or validation failure" do
    webhook = "https://hooks.slack.com/services/T123/B456/ThisMustNeverAppearInHTML"
    patch "/on-call/schedules/#{@schedule.id}/slack_integration",
          params: { integration: { slack_webhook_url: webhook, slack_enabled: "1",
                                   lock_version: @schedule.lock_version } }
    assert_response :see_other
    follow_redirect!
    assert_response :ok
    assert_select "input[type=password][value='']"
    refute_includes response.body, "ThisMustNeverAppearInHTML"
    patch "/on-call/schedules/#{@schedule.id}/slack_integration", params: { integration: { slack_webhook_url: "https://secret.example/InvalidSecret", advance_notice_seconds: "0", lock_version: @schedule.reload.lock_version } }
    assert_response :unprocessable_entity
    refute_includes response.body, "InvalidSecret"
    refute_includes response.body, "ThisMustNeverAppearInHTML"
    assert_select "input[type=password][value='']"
  end

  test "roster display and untouched editor start with computed Next after handoffs" do
    save_rotation([@person.id, @other.id])
    post "/on-call/schedules/#{@schedule.id}/preview_activation"
    post "/on-call/schedules/#{@schedule.id}/activate", params: { proposal_token: proposal_token }
    assert_response :see_other
    get "/on-call/schedules/#{@schedule.id}"
    assert_select ".mn-roster li:first-child", /#{@other.name}/
    get "/on-call/schedules/#{@schedule.id}/rotation/edit"
    assert_select "[data-mn-order] li:first-child input[name='person_ids[]'][value='#{@other.id}']"
    next_end = @schedule.shifts.live.order(:starts_at).second.ends_at
    travel_to(next_end + 1.second) do
      get "/on-call/schedules/#{@schedule.id}/rotation/edit"
      assert_select "[data-mn-order] li:first-child input[name='person_ids[]'][value='#{@other.id}']"
    end
  end

  test "people and schedule collections have complete keyset navigation" do
    @person.update!(name: "ZZ Person")
    @other.update!(name: "ZZ Other")
    51.times { |number| Munawaba::Person.create!(name: format("Page %03d", number), email: "page#{number}-#{SecureRandom.hex(3)}@example.com") }
    get "/on-call/people"
    assert_response :ok
    assert_select "tbody tr", count: 50
    next_page = Nokogiri::HTML(response.body).at_css(".mn-pagination a")["href"]
    get next_page
    assert_response :ok
    assert_select "tbody tr", count: 3
    assert_select "a", "ZZ Person"
  end

  test "a scheduled cancellation crossing its start returns an explicit fresh pause form" do
    @schedule.update!(anchor_local_date: Date.current + 1)
    save_rotation([@person.id])
    post "/on-call/schedules/#{@schedule.id}/preview_activation"
    post "/on-call/schedules/#{@schedule.id}/activate", params: { proposal_token: proposal_token }
    assert_response :see_other
    post "/on-call/schedules/#{@schedule.id}/cancel_scheduled"
    stale = proposal_token
    travel_to(@schedule.reload.coverage_starts_at + 1.second) do
      assert_no_difference("Munawaba::AuditEvent.count") do
        post "/on-call/schedules/#{@schedule.id}/cancel_scheduled", params: { proposal_token: stale }
      end
      assert_response :conflict
      assert_select "h1", "Review pause"
      assert_select "form[action='/on-call/schedules/#{@schedule.id}/pause']"
      fresh = proposal_token
      post "/on-call/schedules/#{@schedule.id}/pause", params: { proposal_token: fresh }
      assert_response :see_other
      assert_equal "pausing", @schedule.reload.state
    end
  end

  test "resume can build a complete roster with only manage schedules capability" do
    @schedule.update!(state: "paused", first_activated_at: Time.current - 2.days, coverage_revision: 1)
    calls = []
    @config.authorize = ->(_controller, capability, record) {
      calls << [capability, record]; capability == :manage_schedules
    }
    post "/on-call/schedules/#{@schedule.id}/preview_resume", params: { edit_order: "add" }
    assert_response :ok
    assert_select "select[name='person_ids[]']"
    assert_equal [[:manage_schedules, @schedule]], calls
    boundary = Munawaba::Timing::BoundaryCalculator.new(@schedule).selectable_boundaries(now: Time.current).first.index
    post "/on-call/schedules/#{@schedule.id}/preview_resume",
         params: { boundary_index: boundary, person_ids: [@other.id, @person.id] }
    assert_response :ok
    fresh = proposal_token
    post "/on-call/schedules/#{@schedule.id}/resume",
         params: { proposal_token: fresh, boundary_index: boundary, person_ids: [@other.id, @person.id] }
    assert_response :see_other
    assert_equal [@other.id, @person.id], @schedule.reload.ordered_person_ids
    assert(calls.all? { |capability, _record| capability == :manage_schedules })
  end

  test "overdue lifecycle labels follow persisted coverage without writes" do
    @schedule.update!(anchor_local_date: Date.current + 1)
    save_rotation([@person.id, @other.id])
    post "/on-call/schedules/#{@schedule.id}/preview_activation"
    post "/on-call/schedules/#{@schedule.id}/activate", params: { proposal_token: proposal_token }
    assert_response :see_other
    starts_at = @schedule.reload.coverage_starts_at
    travel_to(starts_at - 1.second) do
      get "/on-call/schedules/#{@schedule.id}"
      assert_select ".mn-page-heading .mn-badge", "Scheduled"
      assert_select ".mn-maintenance-warning", count: 0
    end
    travel_to(starts_at) do
      assert_no_engine_writes do
        ["/on-call/schedules/#{@schedule.id}", "/on-call/schedules", "/on-call"].each do |path|
          get path
          assert_response :ok
          assert_select ".mn-badge-active", text: "Active"
          assert_select ".mn-maintenance-warning", /Waiting for the next maintenance run/
        end
        get "/on-call/schedules/#{@schedule.id}"
        assert_select ".mn-current-person strong", @person.name
        assert_select "input[value='Pause after current shift']"
        assert_select "button", text: "Cancel scheduled start", count: 0
      end
      assert_equal "scheduled", @schedule.reload.state
      post "/on-call/schedules/#{@schedule.id}/pause"
      post "/on-call/schedules/#{@schedule.id}/pause", params: { proposal_token: proposal_token }
      assert_response :see_other
    end
    travel_to(@schedule.reload.pause_effective_at) do
      assert_no_engine_writes do
        ["/on-call/schedules/#{@schedule.id}", "/on-call/schedules", "/on-call"].each do |path|
          get path
          assert_response :ok
          assert_select ".mn-badge-paused", text: "Paused"
          assert_select ".mn-maintenance-warning", /Waiting for the next maintenance run before you can resume/
        end
        get "/on-call/schedules/#{@schedule.id}"
        assert_select ".mn-current-person strong", "No current coverage"
        assert_select ".mn-badge-next", count: 0
        assert_select "input[value='Preview resume']", count: 0
      end
      assert_equal "pausing", @schedule.reload.state
    end
  end

  test "agenda month and shift detail show actual non-hour DST adjustments without writes" do
    travel_to(Time.utc(2026, 9, 5, 12)) do
      @schedule.update!(anchor_local_date: Date.new(2026, 10, 4), anchor_local_seconds: (2 * 3600) + (15 * 60),
                        time_zone: "Australia/Lord_Howe")
      save_rotation([@person.id])
      post "/on-call/schedules/#{@schedule.id}/preview_activation"
      post "/on-call/schedules/#{@schedule.id}/activate", params: { proposal_token: proposal_token }
      assert_response :see_other
      first = @schedule.shifts.live.order(:starts_at).first
      assert_no_engine_writes do
        ["/on-call/calendar?date=2026-10-01&schedule_id=#{@schedule.id}",
         "/on-call/calendar?view=month&date=2026-10-01&schedule_id=#{@schedule.id}", "/on-call/shifts/#{first.id}"].each do |path|
          get path
          assert_response :ok
          assert_select ".mn-dst-cue", /scheduled 2026-10-04 02:15 Australia\/Lord_Howe/
          assert_select ".mn-dst-cue", /UTC\+11:00; moved forward, 30 minutes/
        end
      end
      original = first.attributes
      travel_to(first.starts_at + 1.hour)
      zone = TZInfo::Timezone.get("UTC")
      Munawaba::Timing::BoundaryCalculator.stubs(:timezone).returns(zone)
      assert_no_engine_writes do
        get "/on-call/shifts/#{first.id}"
        assert_response :ok
        assert_select ".mn-dst-cue", count: 0
      end
      assert_equal original, first.reload.attributes
    end
  end

  test "ambiguous DST handoffs disclose earlier occurrence and exact UTC offset" do
    travel_to(Time.utc(2026, 9, 5, 12)) do
      @schedule.update!(anchor_local_date: Date.new(2026, 11, 1), anchor_local_seconds: 90 * 60,
                        time_zone: "America/New_York")
      save_rotation([@person.id])
      post "/on-call/schedules/#{@schedule.id}/preview_activation"
      post "/on-call/schedules/#{@schedule.id}/activate", params: { proposal_token: proposal_token }
      assert_response :see_other
      assert_no_engine_writes do
        get "/on-call/calendar", params: { date: "2026-11-01", schedule_id: @schedule.id }
        assert_response :ok
        assert_select ".mn-dst-cue", /scheduled 2026-11-01 01:30 America\/New_York/
        assert_select ".mn-dst-cue", /UTC-04:00; earlier occurrence, 0 minutes/
      end
    end
  end

  private

  def assert_no_engine_writes
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, event|
      statements << event[:sql] if event[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE)\b/i)
    end
    yield
    assert_empty statements, statements.join("\n")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def proposal_token
    document = Nokogiri::HTML(response.body)
    input = document.at_css("input[name='proposal_token']")
    assert input, document.text
    input["value"]
  end

  def save_rotation(ids)
    post "/on-call/schedules/#{@schedule.id}/rotation/preview",
         params: { person_ids: ids, lock_version: @schedule.reload.lock_version }
    assert_response :ok
    token = proposal_token
    patch "/on-call/schedules/#{@schedule.id}/rotation", params: { person_ids: ids, proposal_token: token }
    assert_response :see_other
  end
end
