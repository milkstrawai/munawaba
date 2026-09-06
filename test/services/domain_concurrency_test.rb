require "test_helper"
require "timeout"

# Concurrent PostgreSQL sessions need committed fixtures in a private database;
# the usual test transaction would hide those fixtures from other connections.
class DomainConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @original_config = ActiveRecord::Base.connection_db_config.configuration_hash
    @database = "munawaba_concurrency_#{SecureRandom.hex(6)}"
    ActiveRecord::Base.connection.create_database(@database)
    ActiveRecord::Base.establish_connection(@original_config.merge(database: @database, pool: 8))
    paths = [Rails.root.join("../../db/migrate").expand_path.to_s]
    ActiveRecord::MigrationContext.new(paths).migrate
    @people = 2.times.map { |index| Munawaba::Person.create!(name: "Concurrent #{index}", email: "concurrent#{index}@example.org") }
    @schedule = Munawaba::Schedule.create!(name: "Concurrent", cadence: "one_week", time_zone: "UTC",
                                           anchor_local_date: Time.current.to_date - 2, anchor_local_seconds: 9 * 3600)
    @people.each_with_index { |person, position| Munawaba::ScheduleMembership.create!(schedule: @schedule, person: person, position: position) }
    @threads = []
  end

  teardown do
    @threads&.each { |thread| thread.kill if thread.alive? }
    @threads&.each(&:join)
    ActiveRecord::Base.connection_pool.disconnect!
    ActiveRecord::Base.establish_connection(@original_config)
    ActiveRecord::Base.connection.drop_database(@database) if @database
  end

  def preview(operation, subject, attributes = {})
    result = Munawaba::Commands.preview(operation: operation, subject: subject, attributes: attributes, actor: actor)
    assert result.success?, result.errors.inspect
    result.preview
  end

  def submit(operation, subject, proposal, attributes = {})
    Munawaba::Commands.call(operation: operation, subject: subject, attributes: attributes,
                            token: proposal.token, actor: actor, acknowledge_conflicts: true)
  end

  def thread(&block)
    @threads << Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET statement_timeout = '8s'")
        block.call
      end
    rescue StandardError => error
      error
    end
    @threads.last
  end

  def finish(*threads)
    threads.map do |worker|
      assert worker.join(10), "Concurrent command did not finish within its bounded deadline"
      value = worker.value
      raise value if value.is_a?(Exception)

      value
    end
  end

  test "two copies of activation serialize and only one consumes a revision" do
    proposed = preview(:activate, @schedule)
    barrier = Queue.new
    workers = 2.times.map do
      thread do
        barrier.pop
        submit(:activate, Munawaba::Schedule.find(@schedule.id), proposed)
      end
    end
    2.times { barrier << true }
    results = finish(*workers)
    assert_equal [303, 409], results.map(&:status).sort
    assert_equal 1, @schedule.reload.coverage_revision
    assert_equal @schedule.generated_through_boundary - @schedule.coverage_start_boundary + 1, @schedule.shifts.count
  end

  test "deactivation versus roster replacement commits one exact proposal without deadlock" do
    deactivation = preview(:deactivate, @people[1])
    attributes = { person_ids: @people.reverse.map(&:id) }
    rotation = preview(:rotation, @schedule, attributes)
    barrier = Queue.new
    first = thread { barrier.pop; submit(:deactivate, Munawaba::Person.find(@people[1].id), deactivation) }
    second = thread { barrier.pop; submit(:rotation, Munawaba::Schedule.find(@schedule.id), rotation, attributes) }
    2.times { barrier << true }
    assert_equal [303, 409], finish(first, second).map(&:status).sort
    assert_equal (0...@schedule.schedule_memberships.count).to_a,
                 @schedule.schedule_memberships.order(:position).pluck(:position)
    assert @schedule.people.all?(&:active?)
  end

  test "projection foreign-key locks remain compatible with a waiting person deactivation" do
    initial = submit(:activate, @schedule, preview(:activate, @schedule))
    assert initial.success?, initial.errors.inspect
    @schedule.reload
    # Extend coverage while deactivation holds a person lock and waits for this
    # schedule. FOR UPDATE on the person would deadlock with the projection's
    # implicit foreign-key KEY SHARE lock.
    travel 2.weeks
    deactivation = preview(:deactivate, @people[1])
    person_locked, schedule_locked = Queue.new, Queue.new
    remover = thread do
      ActiveRecord::Base.transaction do
        person = Munawaba::Person.where(id: @people[1].id).lock("FOR NO KEY UPDATE").first!
        person_locked << true
        Timeout.timeout(8) { schedule_locked.pop }
        submit(:deactivate, person, deactivation)
      end
    end
    extender = thread do
      Timeout.timeout(8) { person_locked.pop }
      ActiveRecord::Base.transaction do
        schedule = Munawaba::Schedule.where(id: @schedule.id).lock("FOR NO KEY UPDATE").first!
        schedule_locked << true
        Munawaba::Shifts::Project.call(schedule: schedule)
      end
    end
    removal, rows = finish(remover, extender)
    assert rows.any?
    assert_includes [303, 409], removal.status
    assert_equal 0, Munawaba::Shift.connection.select_value(<<~SQL).to_i
      SELECT count(*) FROM munawaba_shifts a JOIN munawaba_shifts b
        ON a.id < b.id AND a.schedule_id = b.schedule_id
        AND a.canceled_at IS NULL AND b.canceled_at IS NULL
        AND tstzrange(a.starts_at,a.ends_at,'[)') && tstzrange(b.starts_at,b.ends_at,'[)')
    SQL
  end

  test "domain confirmation locks retained rows with no-key-update and memberships with update" do
    proposed = preview(:rotation, @schedule, { person_ids: @people.reverse.map(&:id) })
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      statements << payload[:sql] if payload[:sql].include?("FOR ")
    end
    result = submit(:rotation, @schedule, proposed, { person_ids: @people.reverse.map(&:id) })
    assert result.success?, result.errors.inspect
    assert(statements.any? { |sql| sql.include?('"munawaba_people"') && sql.include?("FOR NO KEY UPDATE") })
    assert(statements.any? { |sql| sql.include?('"munawaba_schedules"') && sql.include?("FOR NO KEY UPDATE") })
    assert(statements.any? { |sql| sql.include?('"munawaba_schedule_memberships"') && sql.include?("FOR UPDATE") })
    assert(statements.grep(/FOR UPDATE/).all? { |sql| sql.include?('"munawaba_schedule_memberships"') })
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
