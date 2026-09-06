require "test_helper"
require "action_dispatch/system_test_case"

class AdministrationTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1440, 1000],
                       options: { name: :munawaba_no_javascript } do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_preference("profile.managed_default_content_settings.javascript", 2)
  end

  setup do
    travel_to Time.utc(2026, 9, 5, 12)
    @forgery = ActionController::Base.allow_forgery_protection
    @engine_forgery = Munawaba::ApplicationController.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    Munawaba::ApplicationController.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery
    Munawaba::ApplicationController.allow_forgery_protection = @engine_forgery
    travel_back
  end

  def activate_control(label)
    activate_element(find(:link_or_button, label, match: :prefer_exact))
  end

  def activate_element(element)
    previous_document = page.evaluate_script("performance.timeOrigin")
    element.send_keys(:return)
    Selenium::WebDriver::Wait.new(timeout: 10).until do
      page.evaluate_script("document.readyState === 'complete' && performance.timeOrigin !== #{previous_document}")
    end
  end

  def choose(label, text)
    field = find_field(label)
    field.send_keys(text, :return)
  end

  def fill(label, text)
    field = find_field(label)
    field.send_keys([:control, "a"], text)
  end

  test "complete keyboard operated administration with JavaScript disabled and CSRF enabled" do
    visit "/on-call/people/new"
    assert_selector "h1", text: "Add person"
    page.execute_script("const script=document.createElement('script'); script.textContent='window.mnPageJavaScriptExecuted = true'; document.head.appendChild(script)")
    assert_nil page.evaluate_script("window.mnPageJavaScriptExecuted"), "Page JavaScript must be disabled"
    fill "Display name (required)", "Lina Haddad"
    fill "Organization email (required)", "lina@example.org"
    activate_control "Add person"
    assert_selector "h1", text: "Lina Haddad"
    visit "/on-call/people/new"
    fill "Display name (required)", "Omar Saleh"
    fill "Organization email (required)", "omar@example.org"
    activate_control "Add person"
    assert_selector "h1", text: "Omar Saleh"

    visit "/on-call/schedules/new"
    fill "Schedule name (required)", "Platform"
    fill "IANA timezone (required)", "UTC"
    # Keep today's default 09:00 handoff; activation at the test's 12:00 clock is immediate.
    activate_control "Create schedule"
    assert_selector "h1", text: "Platform"
    assert_text "Draft"
    activate_control "Edit rotation"
    choose "Add an active person", "Lina Haddad"
    activate_control "Update preview"
    assert_text "Lina Haddad"
    choose "Add an active person", "Omar Saleh"
    activate_control "Update preview"
    activate_control "Confirm rotation"
    assert_selector "h1", text: "Platform"

    activate_control "Preview activation"
    assert_selector "h1", text: "Review activation"
    assert_text "Coverage begins when you confirm"
    activate_control "Confirm activate"
    assert_selector "h1", text: "Platform"
    assert_text "Active"
    schedule = Munawaba::Schedule.find_by!(name: "Platform")
    current = schedule.current_shift
    assert_equal "Lina Haddad", current.effective_person.name

    activate_control "Edit rotation"
    activate_element(find("button[aria-label='Move Lina Haddad up']"))
    activate_control "Confirm rotation"
    assert_selector "h1", text: "Platform"
    assert_equal "Lina Haddad", current.reload.effective_person.name
    assert_equal "Lina Haddad", schedule.reload.next_shift.base_person.name

    visit "/on-call/shifts/#{current.id}/override/new"
    choose "Replacement person (required)", "Omar Saleh"
    fill "Reason (optional)", "Planned coverage & support"
    activate_control "Preview override"
    assert_selector "h1", text: "Review override"
    activate_control "Confirm override"
    assert_current_path "/on-call/shifts/#{current.id}"
    assert_equal "Omar Saleh", current.reload.effective_person.name

    visit "/on-call/schedules/#{schedule.id}"
    activate_control "Pause after current shift"
    assert_selector "h1", text: "Review pause"
    activate_control "Confirm pause"
    assert_text "Pausing"
    travel_to current.ends_at
    Munawaba::MaintenanceJob.perform_now
    visit "/on-call/schedules/#{schedule.id}"
    assert_text "Paused"
    activate_control "Preview resume"
    assert_selector "h1", text: "Review resume"
    activate_control "Confirm resume"
    assert_selector "h1", text: "Platform"
    assert_includes %w[active scheduled], schedule.reload.state
    assert_equal 2, schedule.coverage_revision

    visit "/on-call/calendar?view=month&month=2026-09"
    assert_selector "h1", text: "Calendar"
    assert_text "UTC"
    assert_text "Platform"
    assert_selector ".mn-app"
    assert_equal "Inter",
                 page.evaluate_script("getComputedStyle(document.querySelector('.mn-app')).fontFamily").split(",").first.delete('"')
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 1440
    page.save_screenshot(Rails.root.join("../../tmp/screenshots/calendar-dark.png"))
    activate_control "Light theme"
    assert_selector ".mn-app[data-mn-theme='light']"
    page.save_screenshot(Rails.root.join("../../tmp/screenshots/calendar-light.png"))

    page.current_window.resize_to(390, 844)
    visit "/on-call/schedules/#{schedule.id}"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    assert page.evaluate_script("document.querySelector('.mn-app').scrollWidth <= document.querySelector('.mn-app').clientWidth")
    assert_selector "summary", text: "Menu"
    page.save_screenshot(Rails.root.join("../../tmp/screenshots/schedule-mobile.png"))
  end
end
