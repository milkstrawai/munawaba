require "test_helper"
require "tmpdir"
require "open3"
require "pg"

class BlankHostTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "a packaged gem installs once in a new Rails host and preserves its security boundary" do
    root = File.expand_path("../..", __dir__)
    database = "munawaba_blank_#{SecureRandom.hex(4)}"
    source_url = ENV.fetch("DATABASE_URL", "postgres://munawaba:munawaba@127.0.0.1:55432/munawaba_test")
    url = source_url.sub(%r{/[^/]+\z}, "/#{database}")
    admin = PG.connect(source_url.sub(%r{/[^/]+\z}, "/postgres"))
    admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(database)}")

    Dir.mktmpdir("munawaba-blank-host-") do |temporary|
      package = File.join(temporary, "munawaba-#{Munawaba::VERSION}.gem")
      gem_home = File.join(temporary, "gems")
      package_root = File.join(gem_home, "gems", "munawaba-#{Munawaba::VERSION}")
      run_command({}, root, RbConfig.ruby, "-S", "gem", "build", "munawaba.gemspec", "--output", package)
      run_command({}, root, RbConfig.ruby, "-S", "gem", "install", package,
                  "--local", "--ignore-dependencies", "--no-document", "--install-dir", gem_home)

      host = File.join(temporary, "blank_host")
      run_command({ "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "RAILS_ENV" => nil }, root,
                  "bundle", "exec", "rails", "new", host, "--minimal", "--database=postgresql", "--skip-bundle",
                  "--skip-asset-pipeline", "--skip-git", "--skip-test", "--skip-docker", "--skip-brakeman", "--skip-rubocop", "--quiet")
      File.write(File.join(host, "Gemfile"), <<~GEMFILE)
        source "https://rubygems.org"
        gem "rails", "= #{Rails.version}"
        gem "munawaba", "= #{Munawaba::VERSION}"
      GEMFILE
      environment = {
        "BUNDLE_GEMFILE" => File.join(host, "Gemfile"),
        "GEM_HOME" => gem_home,
        "GEM_PATH" => ([gem_home] + Gem.path).uniq.join(File::PATH_SEPARATOR),
        "MUNAWABA_PACKAGE_ROOT" => package_root,
        "DATABASE_URL" => url,
        "RAILS_ENV" => "test",
        "SECRET_KEY_BASE" => "isolated-install-test-only-secret-" * 4
      }
      run_command(environment, host, "bundle", "install", "--local", "--quiet")
      route_before = File.binread(File.join(host, "config/routes.rb"))
      run_command(environment, host, RbConfig.ruby, "bin/rails", "generate", "munawaba:install")
      assert_equal route_before, File.binread(File.join(host, "config/routes.rb"))
      migration_snapshot = Dir[File.join(host, "db/migrate/*.rb")].to_h { |path|
        [File.basename(path), File.binread(path)]
      }
      assert_equal 8, migration_snapshot.size
      run_command(environment, host, RbConfig.ruby, "bin/rails", "generate", "munawaba:install")
      assert_equal(migration_snapshot, Dir[File.join(host, "db/migrate/*.rb")].to_h { |path|
        [File.basename(path), File.binread(path)]
      })
      File.write(File.join(host, "config/routes.rb"),
                 "Rails.application.routes.draw { mount Munawaba::Engine => '/staff/rotations' }\n")
      File.write(File.join(host, "app/controllers/host_admin_controller.rb"), <<~CODE)
        class HostAdminController < ApplicationController
          before_action { response.headers["X-Host-Boundary"] = "present" }
        end
      CODE
      File.write(File.join(host, "config/initializers/munawaba.rb"), <<~CODE)
        Rails.application.config.active_record.schema_format = :ruby
        ActiveJob::Base.queue_adapter = :async
        Rails.application.config.active_record.encryption.primary_key = "blank-host-only-primary-key"
        Rails.application.config.active_record.encryption.deterministic_key = "blank-host-only-deterministic-key"
        Rails.application.config.active_record.encryption.key_derivation_salt = "blank-host-only-salt"
        Munawaba.configure do |config|
          config.parent_controller = "HostAdminController"
          config.authenticate = ->(controller) { controller.request.headers["X-Test-Admin"] == "1" }
          config.authorize = ->(controller, action, record) { controller.request.headers["X-Test-Admin"] == "1" }
          config.actor = ->(controller) { { type: "HostUser", id: "42", name: "Host administrator" } }
          config.application_base_url = "https://startup.example/staff/rotations"
          config.notifications_enabled = false
        end
      CODE
      run_command(environment, host, RbConfig.ruby, "bin/rails", "db:migrate")
      assert File.exist?(File.join(host, "db/schema.rb")), "Host migration should produce schema.rb"
      boot = run_command(environment.merge("RAILS_ENV" => "production", "DATABASE_URL" => "postgres://unused:unused@127.0.0.1:1/unavailable"),
                         host, RbConfig.ruby, "bin/rails", "runner", 'puts "BOOT_WITHOUT_DATABASE"')
      assert_includes boot, "BOOT_WITHOUT_DATABASE"
      File.write(File.join(host, "verify_install.rb"), <<~'CODE')
        require "rack/mock"
        raise "Host loaded the repository instead of the package" unless Munawaba::Engine.root.to_s == ENV.fetch("MUNAWABA_PACKAGE_ROOT")

        rack = Rack::MockRequest.new(Rails.application)
        path = "/staff/rotations"
        authorized = { "HTTP_X_TEST_ADMIN" => "1", "HTTP_HOST" => "malicious.example" }
        response = rack.get(path, authorized)
        raise "Overview status #{response.status}" unless response.status == 200
        raise "Host controller was bypassed" unless response.headers["x-host-boundary"] == "present"
        raise "Authentication did not fail closed" unless rack.get(path).status == 401
        raise "Custom mount missing from HTML" unless response.body.include?("/staff/rotations/people")
        create = rack.post("#{path}/people", authorized.merge(
          "CONTENT_TYPE" => "application/x-www-form-urlencoded",
          input: Rack::Utils.build_nested_query(person: { name: "Blank host person", email: "blank@example.org" })
        ))
        raise "Person registration #{create.status}: #{create.body}" unless create.status == 303
        raise "Host actor not recorded" unless Munawaba::AuditEvent.last.actor_id == "42"
        assets = "#{path}/assets/#{Munawaba::VERSION}"
        asset = rack.get("#{assets}/dashboard.css")
        raise "Engine CSS unavailable without login" unless asset.status == 200 && asset.headers["content-type"].include?("text/css")
        raise "Asset manifest not closed" unless rack.get("#{assets}/secrets.yml").status == 404
        raise "Asset version is not checked" unless rack.get("#{path}/assets/unknown/dashboard.css").status == 404
        raise "Engine JS missing" unless rack.get("#{assets}/dashboard.js").status == 200
        raise "Bundled font missing" unless rack.get("#{assets}/inter.woff2").status == 200
        logo = rack.get("#{assets}/logo.png")
        raise "Engine logo missing" unless logo.status == 200 && logo.headers["content-type"].include?("image/png") && logo.body.b.start_with?("\x89PNG\r\n\x1a\n".b)
        schedule = Munawaba::Schedule.create!(name: "Blank host schedule", cadence: "one_week", time_zone: "UTC", anchor_local_date: Date.new(2026, 9, 1), anchor_local_seconds: 0)
        webhook = "https://hooks.slack.com/services/TEAM/CHANNEL/INSTALL_SECRET"
        schedule.update!(slack_webhook_url: webhook, slack_webhook_configured_at: Time.current)
        ciphertext = ActiveRecord::Base.connection.select_value("SELECT slack_webhook_url FROM munawaba_schedules WHERE id=#{schedule.id}")
        raise "Webhook stored in plaintext" if ciphertext.include?("INSTALL_SECRET")
        raise "Webhook failed to decrypt" unless schedule.reload.slack_webhook_url == webhook
        raise "Wrong schema format" unless Rails.application.config.active_record.schema_format == :ruby
        raise "Missing exclusion" unless ActiveRecord::Base.connection.select_value("SELECT conname FROM pg_constraint WHERE conname='mn_shifts_no_live_overlap'")
        event = Munawaba::AuditEvent.last
        event.update!(actor_name: "Corrected actor")
        event.destroy!
        raise "Host header polluted trusted URL" unless Munawaba.config.application_base_url == "https://startup.example/staff/rotations"
        puts "BLANK_HOST_VERIFIED"
      CODE
      output = run_command(environment, host, RbConfig.ruby, "bin/rails", "runner", "verify_install.rb")
      assert_includes output, "BLANK_HOST_VERIFIED"
    end
  ensure
    if admin && database
      admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(database)} WITH (FORCE)")
      admin.close
    end
  end

  private

  def run_command(environment, directory, *arguments)
    output, error, status = Bundler.with_unbundled_env { Open3.capture3(environment, *arguments, chdir: directory) }
    assert status.success?, "#{arguments.join(" ")} failed:\n#{output}\n#{error}"
    output
  end
end
