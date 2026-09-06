raise "Demo seeds are only for development/test" unless Rails.env.development? || Rails.env.test?

seed_actor = {type: "DemoAdmin", id: "1", name: "Demo administrator"}
Munawaba.config.notifications_enabled = false

seed_people = [
  ["Lina Haddad", "lina@example.org"], ["Omar Saleh", "omar@example.org"],
  ["Noor Kamal", "noor@example.org"], ["Adam Nasser", "adam@example.org"],
  ["Sara Mansour", "sara@example.org"], ["Zaid Ali", "zaid@example.org"]
].map do |name, email|
  Munawaba::Person.find_by(email: email) || begin
    result = Munawaba::Commands.call(operation: :create_person, subject: Munawaba::Person.new,
      attributes: {name: name, email: email}, actor: seed_actor)
    raise result.errors.join(", ") unless result.success?
    result.record
  end
end

def seed_confirm(operation, subject, attributes, actor)
  proposal = Munawaba::Commands.preview(operation: operation, subject: subject, attributes: attributes, actor: actor)
  raise proposal.errors.join(", ") unless proposal.success?
  result = Munawaba::Commands.call(operation: operation, subject: subject, attributes: attributes,
    actor: actor, token: proposal.preview.token, acknowledge_conflicts: true)
  raise result.errors.join(", ") unless result.success?
  result.record
end

today = Date.current
[
  ["Platform", "one_week", "UTC", today - 2, 9 * 3600, [0, 1, 2]],
  ["API & integrations", "one_week", "America/New_York", today - 3, 9 * 3600, [1, 3, 4]],
  ["Infrastructure", "two_weeks", "Europe/Berlin", today - 5, 10 * 3600, [2, 4, 5]],
  ["Security review", "calendar_month", "UTC", Date.new(today.year, 1, 31), 9 * 3600, [3, 0, 5]],
  ["Sydney coverage", "one_week", "Australia/Lord_Howe", Date.new(today.year + 1, 4, 4), 2 * 3600 + 15 * 60, [4, 5]],
  ["Customer support", "one_week", "America/New_York", Date.new(today.year + 1, 3, 14), 2 * 3600 + 30 * 60, [0, 2, 4]]
].each do |name, cadence, zone, date, seconds, positions|
  next if Munawaba::Schedule.exists?(name: name)
  created = Munawaba::Commands.call(operation: :create_schedule, subject: Munawaba::Schedule.new,
    attributes: {name: name, cadence: cadence, time_zone: zone, anchor_local_date: date, anchor_local_seconds: seconds}, actor: seed_actor)
  raise created.errors.join(", ") unless created.success?
  schedule = created.record
  seed_confirm(:rotation, schedule, {person_ids: positions.map { |index| seed_people[index].id }}, seed_actor)
  seed_confirm(:activate, schedule, {}, seed_actor)
  if name == "Platform"
    seed_confirm(:override, schedule.current_shift, {person_id: seed_people[3].id, reason: "Planned coverage for this handoff."}, seed_actor)
  end
end

unless Munawaba::Schedule.exists?(name: "Release operations")
  Munawaba::Commands.call(operation: :create_schedule, subject: Munawaba::Schedule.new,
    attributes: {name: "Release operations", cadence: "two_weeks", time_zone: "UTC", anchor_local_date: today, anchor_local_seconds: 9 * 3600}, actor: seed_actor)
end

puts "Demo ready: #{Munawaba::Person.count} people, #{Munawaba::Schedule.count} schedules. Slack transport is disabled."
