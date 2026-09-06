require "test_helper"

class AuditRecorderTest < ActiveSupport::TestCase
  test "activity records ordinary details without a required actor or fixed event schema" do
    event = Munawaba::Audit::Recorder.record!(event_type: "schedule.reviewed", metadata: { note: "Reviewed" })

    assert_equal({ "note" => "Reviewed" }, event.metadata)
    assert_nil event.actor_id
    assert_nil event.actor_type
    assert event.occurred_at
  end

  test "activity keeps the actor snapshot supplied by the host" do
    event = Munawaba::Audit::Recorder.record!(event_type: "schedule.reviewed",
                                              actor: { "type" => "User", "id" => 42, "name" => "Administrator" })

    assert_equal "User", event.actor_type
    assert_equal "42", event.actor_id
    assert_equal "Administrator", event.actor_name
  end

  test "person changes work without an actor and record field names without copying personal values" do
    person = Munawaba::Person.new
    result = Munawaba::Commands.call(operation: :create_person, subject: person,
                                     attributes: { name: "Private name", email: "private@example.org" })
    assert result.success?, result.errors.inspect

    result = Munawaba::Commands.call(operation: :update_person, subject: person,
                                     attributes: { name: "New private name", email: "new@example.org", lock_version: person.lock_version })
    assert result.success?, result.errors.inspect

    event = person.audit_events.order(:id).last
    assert_equal %w[email name], event.metadata.fetch("changed_fields")
    assert_nil event.actor_id
    refute_includes event.metadata.to_json, "private"
    refute_includes event.metadata.to_json, "@example.org"
  end
end
