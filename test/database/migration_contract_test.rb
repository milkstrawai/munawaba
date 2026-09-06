require "test_helper"
require "pg"
require "stringio"
require "tempfile"

class MigrationContractTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "blank and preinstalled extension installs both retain a host GiST user on rollback" do
    [false, true].each do |preinstalled|
      isolated_database do |connection, _name|
        connection.execute("CREATE EXTENSION btree_gist") if preinstalled
        migrations.migrate
        assert connection.extension_enabled?("btree_gist")
        connection.execute("CREATE TABLE host_example (value integer)")
        connection.execute("CREATE INDEX host_example_gist ON host_example USING gist(value)")
        migrations.down(0)
        assert connection.extension_enabled?("btree_gist")
        assert_equal "host_example_gist",
                     connection.select_value("SELECT indexrelid::regclass::text FROM pg_index WHERE indrelid='host_example'::regclass")
        assert_empty connection.tables.grep(/^munawaba_/)
        assert_nil connection.select_value("SELECT proname FROM pg_proc WHERE proname='munawaba_reject_audit_mutation'")
      end
    end
  end

  test "install without database extension privileges reports actionable requirement" do
    isolated_database do |connection, _name|
      role = "mn_install_#{SecureRandom.hex(4)}"
      connection.execute("CREATE ROLE #{role}")
      begin
        connection.execute("GRANT USAGE,CREATE ON SCHEMA public TO #{role}")
        connection.execute("SET ROLE #{role}")
        error = assert_raises(StandardError) { migrations.migrate }
        assert_includes error.message, "Ask the database owner to CREATE EXTENSION btree_gist"
      ensure
        connection.execute("RESET ROLE")
        connection.execute("DROP OWNED BY #{role} CASCADE")
        connection.execute("DROP ROLE #{role}")
      end
    end
  end

  test "installation reports PostgreSQL prerequisites before creating tables" do
    isolated_database do |connection, _name|
      connection.stubs(:database_version).returns(140000)
      error = assert_raises(StandardError) { migrations.migrate }
      assert_includes error.message, "Munawaba requires PostgreSQL 15 or later"
      assert_empty connection.tables.grep(/^munawaba_/)
    end
  end

  test "Ruby schema dump load preserves deferred overlap checks references and mutable activity" do
    dump = StringIO.new
    isolated_database do |_connection, _name|
      migrations.migrate
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, dump)
      assert_includes dump.string, "mn_shifts_no_live_overlap"
      assert_not_includes dump.string, "munawaba_reject_audit_mutation"
    end
    isolated_database do |connection, _name|
      Tempfile.create(["munawaba-schema", ".rb"]) do |schema|
        schema.write(dump.string)
        schema.flush
        load schema.path
      end
      assert connection.extension_enabled?("btree_gist")
      assert connection.select_value("SELECT condeferrable FROM pg_constraint WHERE conname='mn_shifts_no_live_overlap'")
      person = Munawaba::Person.create!(name: "Schema person", email: "schema@example.org")
      schedule = Munawaba::Schedule.create!(name: "Schema schedule", cadence: "one_week", time_zone: "UTC",
                                            anchor_local_date: Date.new(2026, 9, 5), anchor_local_seconds: 0)
      now = Time.utc(2026, 9, 5)
      fields = { schedule: schedule, base_person: person, effective_person: person,
                 coverage_revision: 1, generated_at: now }
      first = Munawaba::Shift.create!(**fields, boundary_index: 0, starts_at: now, ends_at: now + 1.week)
      second = Munawaba::Shift.create!(**fields, boundary_index: 1, starts_at: now + 1.week, ends_at: now + 2.weeks)
      assert_raises(ActiveRecord::StatementInvalid) { first.update_columns(ends_at: now + 8.days) }
      connection.transaction do
        connection.execute("SET CONSTRAINTS mn_shifts_no_live_overlap DEFERRED")
        first.update_columns(ends_at: now + 8.days)
        second.update_columns(starts_at: now + 8.days)
      end
      assert_equal first.reload.ends_at, second.reload.starts_at
      assert_raises(ActiveRecord::StatementInvalid) { first.update_columns(ends_at: first.starts_at) }
      error = assert_raises(ActiveRecord::StatementInvalid) { person.delete }
      assert_includes [PG::ForeignKeyViolation, PG::RestrictViolation], error.cause.class
      event = Munawaba::AuditEvent.create!(operation_id: SecureRandom.uuid, event_type: "host.note",
                                           metadata: {}, occurred_at: now)
      assert event.update!(metadata: { corrected: true })
      assert event.destroy!
    end
  end

  test "upgrade removes legacy activity restrictions without changing existing rows" do
    isolated_database do |connection, _name|
      migrations.migrate(20260905000007)
      connection.add_check_constraint :munawaba_audit_events, "event_type = 'person.created'", name: "mn_audit_catalog"
      connection.add_check_constraint :munawaba_audit_events, "actor_type IS NOT NULL AND actor_id IS NOT NULL", name: "mn_audit_actor"
      connection.add_check_constraint :munawaba_audit_events, "metadata ? 'schema_version' AND metadata ? 'source'", name: "mn_audit_envelope"
      connection.execute <<~SQL
        CREATE FUNCTION munawaba_reject_audit_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'Munawaba activity is append-only' USING ERRCODE = '55000';
        END;
        $$;
        CREATE TRIGGER munawaba_audit_append_only BEFORE UPDATE OR DELETE ON munawaba_audit_events
        FOR EACH ROW EXECUTE FUNCTION munawaba_reject_audit_mutation();
      SQL
      event = Munawaba::AuditEvent.create!(operation_id: SecureRandom.uuid, event_type: "person.created",
                                           actor_type: "User", actor_id: "1", metadata: { schema_version: 1, source: "human" }, occurred_at: Time.current)
      original = event.reload.attributes
      assert_raises(ActiveRecord::StatementInvalid) { event.update_columns(actor_name: "Changed") }

      migrations.migrate
      assert_equal original, event.reload.attributes
      assert_nil connection.select_value("SELECT proname FROM pg_proc WHERE proname='munawaba_reject_audit_mutation'")
      assert_nil connection.select_value("SELECT tgname FROM pg_trigger WHERE tgname='munawaba_audit_append_only'")
      assert event.update!(event_type: "host.note", actor_type: nil, actor_id: nil, metadata: {})
      assert event.destroy!
    end
  end

  test "concurrent leaf batches skip locked claims without selecting duplicate deliveries" do
    isolated_database do |connection, _name|
      migrations.migrate
      schedule = Munawaba::Schedule.create!(name: "Claim fixture", cadence: "one_week", time_zone: "UTC",
                                            anchor_local_date: Date.new(2026, 9, 5), anchor_local_seconds: 0)
      now = Time.utc(2026, 9, 5, 12)
      3.times do |index|
        Munawaba::NotificationDelivery.create!(schedule: schedule, kind: "test", status: "pending",
                                               event_key: "claim:#{index}", notification_revision: 0, context: { "schema_version" => 1 }, due_at: now - 120, next_attempt_at: now - 60, expires_at: now - 1)
      end
      first = PG.connect(@isolated_url)
      second = PG.connect(@isolated_url)
      begin
        { "next_attempt_at" => "status='pending'", "expires_at" => "status='pending'",
          "lease_expires_at" => "status IN ('enqueued','processing')" }.each do |field, predicate|
          if field == "lease_expires_at"
            connection.execute("UPDATE munawaba_notification_deliveries SET status='enqueued',next_attempt_at=NULL,claim_token='00000000-0000-4000-8000-000000000001',enqueued_at='2026-09-05 11:00Z',lease_expires_at='2026-09-05 11:30Z'")
          end
          first.exec("BEGIN")
          second.exec("BEGIN")
          begin
            second.exec("SET LOCAL lock_timeout='200ms'")
            sql = "SELECT id FROM munawaba_notification_deliveries WHERE #{predicate} AND #{field}<=$1 ORDER BY #{field},id LIMIT 2 FOR UPDATE SKIP LOCKED"
            left = first.exec_params(sql, [now.iso8601]).column_values(0)
            right = second.exec_params(sql, [now.iso8601]).column_values(0)
            assert_equal 2, left.size
            assert_equal 1, right.size
            assert_empty left & right
          ensure
            first.exec("ROLLBACK")
            second.exec("ROLLBACK")
          end
        end
      ensure
        first.close
        second.close
      end
    end
  end

  private

  def migrations
    ActiveRecord::MigrationContext.new([File.expand_path("../../db/migrate", __dir__)])
  end

  def isolated_database
    original = ActiveRecord::Base.connection_db_config.configuration_hash
    name = "munawaba_migration_#{SecureRandom.hex(4)}"
    url = ENV.fetch("DATABASE_URL", "postgres://munawaba:munawaba@127.0.0.1:55432/munawaba_test")
    @isolated_url = url.sub(%r{/[^/]+\z}, "/#{name}")
    admin = PG.connect(url.sub(%r{/[^/]+\z}, "/postgres"))
    admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)}")
    ActiveRecord::Base.establish_connection(@isolated_url)
    yield ActiveRecord::Base.connection, name
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if original
    ActiveRecord::Base.establish_connection(original) if original
    if admin && name
      admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)")
      admin.close
    end
  end
end
