# frozen_string_literal: true

require "pg"
require "json"
require "fileutils"
require "uri"
ENV["RAILS_ENV"] = "test"
require_relative "../dummy/config/environment"

module MunawabaJobBenchmarks
  ROOT = File.expand_path("../..", __dir__)
  REPORT = File.join(ROOT, "tmp/performance/job-benchmarks.json")
  BUDGETS = File.join(__dir__, "job_budgets.json")
  NOW = Time.utc(2026, 9, 5, 12)
  SAMPLES = 5
  HISTORICAL_SLOTS = [5, 20_000].freeze
  APPEND_COUNTS = [2, 8].freeze

  module_function

  def assert!(condition, message)
    raise message unless condition
  end

  def measure
    queries = 0
    loaded_shifts = 0
    subscribers = [
      ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        queries += 1 unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)
      end,
      ActiveSupport::Notifications.subscribe("instantiation.active_record") do |_name, _start, _finish, _id, payload|
        loaded_shifts += payload[:record_count] if payload[:class_name] == "Munawaba::Shift"
      end
    ]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = yield
    { milliseconds: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3), queries: queries,
      instantiated_shifts: loaded_shifts, value: value }
  ensure
    subscribers&.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
  end

  def rollback
    result = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      result = yield
      raise ActiveRecord::Rollback
    end
    result
  end

  def summarize(samples)
    times = samples.map { |sample| sample.fetch(:milliseconds) }.sort
    { samples: samples, median_ms: times[times.length / 2], p95_ms: times[(times.length * 0.95).ceil - 1],
      maximum_queries: samples.map { |sample| sample.fetch(:queries) }.max,
      maximum_instantiated_shifts: samples.map { |sample| sample.fetch(:instantiated_shifts) }.max }
  end

  def reset_sequences(connection)
    %w[people schedules schedule_memberships shifts shift_overrides notification_deliveries audit_events].each do |name|
      table = "munawaba_#{name}"
      connection.exec("SELECT setval(pg_get_serial_sequence('#{table}','id'),coalesce((SELECT max(id) FROM #{table}),1),true)")
    end
  end

  def extension_schedule(connection, history, missing)
    person = Munawaba::Person.create!(name: "Benchmark #{history}/#{missing}",
                                      email: "benchmark#{history}-#{missing}@example.org")
    anchor = NOW.to_date - (history * 7)
    schedule = Munawaba::Schedule.create!(name: "Benchmark #{history}/#{missing}", cadence: "one_week", time_zone: "UTC",
                                          anchor_local_date: anchor, anchor_local_seconds: 43_200)
    Munawaba::ScheduleMembership.create!(schedule: schedule, person: person, position: 0)
    calculator = Munawaba::Timing::BoundaryCalculator.new(schedule)
    target = calculator.slot_at(NOW + Munawaba::Defaults::SHIFT_GENERATION_HORIZON)
    cursor = target - missing
    first = calculator.boundary(0).resolved_at
    connection.exec_params(<<~SQL, [schedule.id, person.id, first.iso8601(6), cursor, NOW.iso8601(6)])
      INSERT INTO munawaba_shifts(schedule_id,coverage_revision,boundary_index,starts_at,ends_at,
        base_person_id,effective_person_id,rotation_revision,assignment_version,timing_version,generated_at,lock_version,created_at,updated_at)
      SELECT $1::bigint,1,n,$3::timestamptz+n*interval '1 week',$3::timestamptz+(n+1)*interval '1 week',
        $2::bigint,$2::bigint,1,1,1,$5::timestamptz,0,$3::timestamptz,$3::timestamptz
      FROM generate_series(0,$4::integer) n
    SQL
    schedule.update!(state: "active", first_activated_at: first, coverage_revision: 1, coverage_start_boundary: 0,
                     coverage_starts_at: first, generated_through_boundary: cursor, rotation_revision: 1, rotation_effective_boundary: 0, lifecycle_revision: 1)
    [schedule, target, cursor - history + 1, history, missing]
  end

  def dispatcher_samples(adapter)
    results = []
    (SAMPLES + 1).times do |index|
      result = rollback do
        adapter.enqueued_jobs.clear
        first = measure { Munawaba::Notifications::Dispatcher.call(now: NOW) }
        first_ids = adapter.enqueued_jobs.map { |job| job.fetch(:args).first }
        adapter.enqueued_jobs.clear
        second = measure { Munawaba::Notifications::Dispatcher.call(now: NOW) }
        second_ids = adapter.enqueued_jobs.map { |job| job.fetch(:args).first }
        assert!(first[:value] == 100 && second[:value] == 100,
                "Dispatcher must claim exactly 100 rows per bounded batch")
        assert!(first_ids.length == 100 && second_ids.length == 100, "Each claim must enqueue one ID/token job")
        assert!(first_ids.uniq == first_ids && second_ids.uniq == second_ids && (first_ids & second_ids).empty?,
                "Dispatcher selected duplicate rows")
        first.merge(second_batch_milliseconds: second[:milliseconds], claimed: first_ids.length,
                    disjoint_next_batch: true).except(:value)
      end
      results << result if index.positive?
    end
    summarize(results)
  end

  def projection_samples(schedule, target, live_window, inserted)
    samples = []
    (SAMPLES + 1).times do |index|
      sample = rollback do
        schedule.reload
        result = measure { Munawaba::Shifts::Project.call(schedule: schedule, observed_revision: schedule.coverage_revision, now: NOW) }
        rows = result.delete(:value)
        assert!(rows.length == inserted, "A horizon sample must append exactly its requested missing slots")
        assert!(schedule.reload.generated_through_boundary == target,
                "Projection cursor did not reach the bounded target")
        assert!(rows.map(&:boundary_index) == ((target - inserted + 1)..target).to_a,
                "Projection appended unexpected slots")
        assert!(result[:instantiated_shifts] <= live_window + inserted,
                "Maintenance instantiated retained historical shifts")
        result.merge(inserted: rows.length, existing_live_window: live_window)
      end
      samples << sample if index.positive?
    end
    summarize(samples)
  end

  def run
    url = ENV.fetch("MUNAWABA_JOB_DATABASE_URL") do
      ENV.fetch("MUNAWABA_PERFORMANCE_DATABASE_URL",
                "postgres://munawaba:munawaba@127.0.0.1:55432/munawaba_jobs_performance")
    end
    uri = URI(url)
    name = uri.path.delete_prefix("/")
    assert!(name.match?(/\A[a-zA-Z0-9_]+_performance\z/), "Use a disposable *_performance database")
    admin_uri = uri.dup
    admin_uri.path = "/postgres"
    admin = PG.connect(admin_uri.to_s)
    admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)}")
    ActiveRecord::Base.establish_connection(url)
    ActiveRecord::Migration.verbose = false
    ActiveRecord::MigrationContext.new([File.join(ROOT, "db/migrate")]).migrate
    connection = PG.connect(url)
    connection.exec(File.read(File.join(ROOT, "test/database/query_plan_fixture.sql")))
    reset_sequences(connection)
    # Preserve the fixture's status distribution, but keep pending rows unexpired
    # so this benchmark measures claims rather than expiration cleanup.
    connection.exec_params("UPDATE munawaba_notification_deliveries SET expires_at=$1 WHERE status='pending'",
                           [(NOW + 1.day).iso8601(6)])
    schedules = APPEND_COUNTS.flat_map { |missing|
      HISTORICAL_SLOTS.map { |history|
        extension_schedule(connection, history, missing)
      }
    }
    connection.exec("ANALYZE")
    adapter = ActiveJob::QueueAdapters::TestAdapter.new
    adapter.perform_enqueued_jobs = false
    adapter.perform_enqueued_at_jobs = false
    ActiveJob::Base.queue_adapter = adapter
    ActiveJob::Base.logger = Logger.new(File::NULL)
    Munawaba.config.notifications_enabled = true
    report = {
      recorded_at: Time.current.utc.iso8601(6), database_version: connection.exec("SHOW server_version").getvalue(0, 0),
      ruby_version: RUBY_VERSION, rails_version: Rails.version, clock: NOW.iso8601(6), warmup_runs: 1, measured_runs: SAMPLES,
      fixture_counts: %w[people schedules shifts notification_deliveries audit_events].to_h { |table|
        [table, connection.exec("SELECT count(*) FROM munawaba_#{table}").getvalue(0, 0).to_i]
      },
      dispatcher: dispatcher_samples(adapter), projection: {}
    }
    schedules.each do |schedule, target, live_window, history, inserted|
      report[:projection]["#{history}_history_#{inserted}_inserted"] =
        projection_samples(schedule, target, live_window, inserted)
    end
    APPEND_COUNTS.each do |inserted|
      young, old = HISTORICAL_SLOTS.map { |history|
        report[:projection].fetch("#{history}_history_#{inserted}_inserted")
      }
      assert!(young[:maximum_queries] == old[:maximum_queries], "Projection query count grew with retained history")
      assert!(young[:maximum_instantiated_shifts] == old[:maximum_instantiated_shifts],
              "Projection loaded more models for the older schedule")
    end
    projections = report[:projection].values
    report[:fixture_counts_after] = report[:fixture_counts].keys.to_h do |table|
      [table, connection.exec("SELECT count(*) FROM munawaba_#{table}").getvalue(0, 0).to_i]
    end
    assert!(report[:fixture_counts] == report[:fixture_counts_after],
            "A rolled-back sample changed retained fixture counts")
    budgets = JSON.parse(File.read(BUDGETS)).symbolize_keys
    report[:budgets] = budgets
    FileUtils.mkdir_p(File.dirname(REPORT))
    File.write(REPORT, JSON.pretty_generate(report) + "\n")
    assert!(report[:dispatcher][:p95_ms] <= budgets[:dispatcher_ms],
            "Dispatcher latency exceeded the recorded budget")
    assert!(report[:dispatcher][:maximum_queries] <= budgets[:dispatcher_queries],
            "Dispatcher query count exceeded the recorded budget")
    projections.each do |sample|
      assert!(sample[:p95_ms] <= budgets[:projection_ms], "Projection latency exceeded the recorded budget")
      inserted = sample[:samples].first.fetch(:inserted)
      query_budget = budgets[:projection_fixed_queries] + (inserted * budgets[:projection_queries_per_inserted])
      assert!(sample[:maximum_queries] <= query_budget,
              "Projection query count exceeded the measured per-generated-row budget")
      assert!(sample[:maximum_instantiated_shifts] <= budgets[:projection_instantiated_shifts],
              "Projection model count exceeded the recorded budget")
    end
    puts JSON.pretty_generate(report)
  ensure
    adapter&.enqueued_jobs&.clear
    connection&.close
    admin&.close
  end
end

MunawabaJobBenchmarks.run if $PROGRAM_NAME == __FILE__
