require "test_helper"
require "action_dispatch/system_test_case"

class AccessibilityTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1440, 1000],
                       options: { name: :munawaba_accessibility } do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
  end

  test "desktop and mobile screens have no WCAG A AA violations and load only local assets" do
    axe_path = File.expand_path("../../tmp/browser-tools/axe.min.js", __dir__)
    skip "Run bin/browser-setup to install the development-only axe runner" unless File.exist?(axe_path)
    seed_actor = { type: "User", id: "1", name: "Test administrator" }
    person = Munawaba::Person.create!(name: "Lina Haddad", email: "lina@example.org")
    schedule = Munawaba::Schedule.create!(name: "Platform", cadence: "one_week", time_zone: "UTC",
                                          anchor_local_date: Date.current - 1, anchor_local_seconds: 9 * 3600)
    Munawaba::ScheduleMembership.create!(schedule: schedule, person: person, position: 0)
    preview = Munawaba::Commands.preview(operation: :activate, subject: schedule, actor: seed_actor)
    result = Munawaba::Commands.call(operation: :activate, subject: schedule, actor: seed_actor,
                                     token: preview.preview.token, acknowledge_conflicts: true)
    assert result.success?, result.errors.inspect
    pages = ["/on-call", "/on-call/people", "/on-call/people/new", "/on-call/schedules/#{schedule.id}",
             "/on-call/schedules/#{schedule.id}/rotation/edit", "/on-call/calendar", "/on-call/calendar?view=month",
             "/on-call/activity", "/on-call/schedules/#{schedule.id}/slack_integration/edit", "/on-call/notification_deliveries"]
    %w[dark light].each do |theme|
      if theme == "light"
        click_button "Light theme"
        assert_selector ".mn-app[data-mn-theme='light']"
      end
      pages.each do |path|
        visit path
        assert_selector ".mn-app"
        assert_equal "Inter",
                     page.evaluate_script("getComputedStyle(document.querySelector('.mn-app')).fontFamily").split(",").first.delete('"')
        page.execute_script(File.read(axe_path))
        result = page.driver.browser.execute_async_script("const done=arguments[arguments.length-1]; axe.run(document.querySelector('.mn-app'), {runOnly:{type:'tag',values:['wcag2a','wcag2aa','wcag21aa']}}, (error,result)=>done(error ? {error:String(error)} : {violations:result.violations.map(v=>({id:v.id,impact:v.impact,nodes:v.nodes.map(n=>n.target)}))}));")
        assert_empty result.fetch("violations"), "#{theme} #{path}: #{result.inspect}"
        remote = page.evaluate_script("performance.getEntriesByType('resource').filter(r=>new URL(r.name).origin!==location.origin).map(r=>r.name)")
        assert_empty remote, "Runtime resources must remain local"
        assert_empty page.driver.browser.logs.get(:browser).select { |entry| entry.level == "SEVERE" }.map(&:message)
      end
    end
    page.current_window.resize_to(390, 844)
    visit "/on-call/schedules/#{schedule.id}"
    assert page.evaluate_script("document.querySelector('.mn-app').scrollWidth <= document.querySelector('.mn-app').clientWidth")
    page.execute_script(File.read(axe_path))
    result = page.driver.browser.execute_async_script("const done=arguments[arguments.length-1]; axe.run(document.querySelector('.mn-app'), {runOnly:{type:'tag',values:['wcag2a','wcag2aa','wcag21aa']}}, (error,result)=>done(error ? {error:String(error)} : {violations:result.violations.map(v=>({id:v.id,nodes:v.nodes.map(n=>n.target)}))}));")
    assert_empty result.fetch("violations"), result.inspect
  end
end
