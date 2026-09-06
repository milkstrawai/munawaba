# Usage and reference

Start with [installation](../README.md#installation), then use this guide for configuration and day-to-day scheduling.

- [Dashboard](#dashboard)
- [Scheduling](#scheduling)
- [Access](#access)
- [Configuration](#configuration)
- [Slack notifications](#slack-notifications)
- [Maintenance](#maintenance)
- [Upgrading](#upgrading)

## Dashboard

**Overview** shows who is on call. **Calendar** shows upcoming coverage, filtered by schedule or person, in Agenda or Month view. Handoffs show their timezone and any DST adjustment.

Manage a roster from its schedule page. The first person is the regular **Next** assignee; reorder with the move buttons, **Make next**, or drag rows. Review the preview before confirming. It shows up to six assignments and all detected conflicts. Editing the roster requires a new preview.

Use **People** to add or deactivate teammates. **Activity** records changes to people, schedules, rotations, overrides, Slack settings, and projection maintenance. Filter by schedule, person, shift, actor, event, or date. The [actor callback](#access) attributes changes to a person.

## Scheduling

A schedule rotates up to 100 active people through shifts. A shift's **base person** comes from the rotation; its **effective person** includes any override.

Reordering an active rotation takes effect after the current shift. For a scheduled run, it takes effect at the first shift. Overrides stay attached to their shifts.

An override replaces one whole shift. Revoking it restores the base person, who must still be active. Completed and canceled shifts cannot be reassigned. Conflicts across schedules require acknowledgment, but another schedule can change after confirmation and introduce a conflict.

### Lifecycle

| State       | Behavior                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------- |
| `draft`     | Choose timing and a roster, then activate.                                                  |
| `scheduled` | Coverage starts at the selected future handoff; cancel before it starts.                    |
| `active`    | Roster changes affect future coverage; pause keeps the current shift through its end.       |
| `pausing`   | The current shift finishes without a successor, then maintenance marks the schedule paused. |
| `paused`    | Resume at a selected handoff with the chosen roster.                                        |

Canceling a scheduled run returns it to `draft` if it has never started, otherwise `paused`. Resume creates new shifts and keeps canceled coverage in history. Commands account for due starts and pauses even before maintenance updates the saved state.

### Handoffs

Timing consists of a cadence, IANA timezone, anchor date, and local handoff time. It can change only on a draft whose first run has not started. At a handoff, the incoming shift owns that instant: intervals include their start and exclude their end.

Weekly and fortnightly boundaries advance 7 or 14 days from the original anchor. Monthly boundaries keep the original day, capped by the month's length: January 31 → February 28 or 29 → March 31.

During DST transitions, an ambiguous time uses the earlier UTC occurrence. A nonexistent time moves forward by the timezone gap, including half-hour gaps. The next handoff returns to the nominal local time.

Future activation and resume keep the selected handoff; confirm before it passes. Immediate activation starts at confirmation time inside the reviewed slot. Once that slot ends, its preview is stale. Later shifts and the final boundary must match the preview and still cover the configured calendar window.

### Deactivation

Deactivation removes a person from rosters. It is blocked by a future override or being the last member of an active or scheduled roster. A current override may finish; draft, paused, and pausing rosters may become empty.

The roster keeps its regular Next assignee when possible, otherwise the next active survivor in rotation. Overrides do not choose the successor. Reactivation makes the person selectable without restoring former memberships.

### Commands

Use `Munawaba::Commands` for scheduling changes. Activation, resume, roster changes, overrides, pause, cancellation, and deactivation require a preview:

- `preview` accepts `operation:`, `subject:`, optional `attributes:`, and optional `actor:`.
- `call` accepts the same inputs plus `token:` and, for conflicts, `acknowledge_conflicts: true`.

Previews calculate all affected assignments and conflicts without saving. Their signed tokens bind the inputs and proposed outcome. Confirmation locks affected records and recalculates before saving; other schedules remain unlocked during conflict checks.

Results expose `success?`, `status`, `record`, `errors`, and `preview`. Success returns 303; invalid input or missing conflict acknowledgment returns 422. A stale confirmation returns 409 with a refreshed preview when available.

Inside an existing transaction, commands use a savepoint and enqueue notifications after the outer transaction commits.

## Access

Munawaba calls `authenticate.call(controller)`, then `authorize.call(controller, capability, record)`. Both must return exactly `true`. Missing or denied authentication returns 401; missing or denied authorization returns 403. Rendering or redirecting from a callback ends the request.

| Surface                                        | Capability            | Authorization record                      |
| ---------------------------------------------- | --------------------- | ----------------------------------------- |
| Overview/calendar                              | `read`                | `:overview` / `:calendar`                 |
| People/schedules lists                         | `read`                | `Munawaba::Person` / `Munawaba::Schedule` |
| Person/schedule/shift detail                   | `read`                | Loaded record                             |
| Person new/create                              | `manage_people`       | `Munawaba::Person`                        |
| Person edit/update/deactivation/reactivation   | `manage_people`       | Loaded person                             |
| Schedule new/create                            | `manage_schedules`    | `Munawaba::Schedule`                      |
| Schedule edit/update/lifecycle actions         | `manage_schedules`    | Loaded schedule                           |
| Rotation preview/edit/save                     | `manage_rotations`    | Owning schedule                           |
| Override preview/create/replace/revoke/restore | `override_shifts`     | Owning shift                              |
| Slack settings/update/remove/test              | `manage_integrations` | Owning schedule                           |
| Delivery history                               | `manage_integrations` | `:notification_deliveries`                |
| Manual retry                                   | `manage_integrations` | Loaded delivery                           |
| Activity                                       | `view_audit`          | `:activity`                               |
| Theme                                          | `read`                | `:theme`                                  |
| Packaged assets                                | Public                | No callback                               |

Authorize the whole action: deactivation changes affected rosters, and resume includes its selected roster order. Ruby calls to `Munawaba::Commands` skip these callbacks; check permissions before invoking them.

For Activity attribution, set `actor` to a callback returning `{ type: "User", id: user.id.to_s, name: user.name }`, or `nil` when no attribution is needed.

## Configuration

Configure these settings in `config/initializers/munawaba.rb`. The [README](../README.md#installation) has a starting example.

| Setting                                                             | Purpose and default                                                                      |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `parent_controller`                                                 | Controller class name, derived from `ActionController::Base`; `"ApplicationController"`  |
| `authenticate`, `authorize`                                         | Access callbacks; unset callbacks deny access                                            |
| `actor`                                                             | Optional activity attribution; `nil`                                                     |
| `application_base_url`                                              | Mounted HTTPS engine URL, such as `https://example.com/on-call`; `nil` omits Slack links |
| `default_schedule_time_zone`                                        | Initial schedule timezone; `"UTC"`                                                       |
| `organization_time_zone`                                            | Organization calendar and activity timezone; `"UTC"`                                     |
| `week_starts_on`                                                    | Calendar week start; `:monday`                                                           |
| `calendar_past_limit`, `calendar_future_limit`, `calendar_max_span` | 24 months back, 12 months ahead, 3 months per request                                    |
| `job_queue_name`                                                    | Active Job queue; `:munawaba`                                                            |
| `notifications_enabled`                                             | Send Slack notifications; `false`                                                        |
| `slack_allowed_hosts`                                               | Exact webhook hostnames; `["hooks.slack.com"]`                                           |
| `maintenance_mode`                                                  | Pause scheduling commands and Slack delivery; `false`                                    |

Use IANA timezone names. `calendar_future_limit` can extend to 13 months, the scheduling horizon.

`notifications_enabled` and `maintenance_mode` also accept zero-argument callables. Only `true` enables delivery; only `false` clears maintenance mode. A `nil` result or callback error leaves delivery off or maintenance on.

## Slack notifications

Each schedule can send advance reminders, shift-start messages, assignment changes, and a summary when its next regular assignee changes.

Configure Active Record Encryption, save a webhook in the schedule's Slack settings, enable the integration, and set `notifications_enabled` to `true`. Use **Send test message**, even before activation, and check delivery history for the result.

Delivery requires a durable Active Job queue and the [recurring jobs](../README.md#background-jobs). Delivery jobs must run outside database transactions so Munawaba can record an attempt before contacting Slack.

### Delivery history

| Status       | Meaning                                                      |
| ------------ | ------------------------------------------------------------ |
| `pending`    | Waiting for its due time or a retry                          |
| `enqueued`   | Waiting for a worker                                         |
| `processing` | Sending to Slack                                             |
| `delivered`  | Slack returned success                                       |
| `failed`     | Permanent failure or exhausted retries                       |
| `stale`      | Expired or superseded by scheduling or settings changes      |
| `canceled`   | Coverage, the integration, or that message kind was disabled |

Before sending, Munawaba checks the assignment, timing, and settings. Messages expire at:

| Message                | Expiration                                                  |
| ---------------------- | ----------------------------------------------------------- |
| Advance reminder       | Shift start                                                 |
| Shift start            | One hour after start                                        |
| Assignment change      | Earlier of shift end or 24 hours after the override change  |
| Next-assignment change | Earlier of the described handoff or 24 hours after creation |
| Test                   | Ten minutes after creation                                  |

### Retries and uncertain outcomes

Temporary network failures and HTTP 408, 429, and 5xx responses retry automatically, up to eight attempts within the original deadline. A numeric `Retry-After` up to one hour is honored for HTTP 429; larger values fail. Other HTTP failures, redirects, and certificate failures need attention before retrying.

A timeout or stopped worker can leave the outcome unknown: Slack may have received the message. The warning stays through automatic retries until one succeeds. A manual retry requires acknowledging that it could post a duplicate.

After fixing the cause, **Retry** creates a new delivery using current Slack settings, preserving the original assignment and deadline. Each failed delivery allows one manual retry while still relevant and unexpired; its original result stays in history. Replacing a webhook alone does not replay failed messages.

### Settings changes

Changing a webhook or notification settings replaces pending messages that still apply. Requests already being sent can still arrive. Re-enabling assignment notifications sends new changes without replaying changes made while disabled. Messages use people's current names when sent.

## Maintenance

Run the [minute and daily jobs](../README.md#background-jobs) to apply scheduled starts and pauses, recover deliveries, and maintain future coverage.

`maintenance_mode = true` pauses scheduling previews, commands, and Slack delivery. Background maintenance continues; Slack settings, test requests, and manual retries can still record work.

`notifications_enabled = false` pauses only delivery. Messages are still recorded and may be sent when re-enabled if relevant and unexpired.

### Timezone-data updates

Web and worker processes sharing a database need the same timezone rules:

1. Enable `maintenance_mode`, pause recurring enqueueing and queue consumption, and let running Munawaba jobs finish.
2. Deploy the same application and timezone data to every web and worker process.
3. Run `Munawaba::MaintainProjectionJob.perform_now`. Resolve schedule failures before resuming jobs and disabling maintenance mode.

After recalculation, keep all processes on the new rules. Current and completed shifts retain their saved times. The first future shift meets its predecessor's saved end; later handoffs follow the new rules. Overrides stay attached.

A future run's corrected start may become due. Repair then starts it at the current instant if its first shift still has time remaining; otherwise repair fails. Repair such runs before deactivation; they can no longer be canceled as future starts.

Timing mismatches stop Slack delivery and request repair. Mismatches in already-started shifts need investigation because repair preserves their saved times.

### Troubleshooting

| Symptom                                   | Check                                                                       |
| ----------------------------------------- | --------------------------------------------------------------------------- |
| Due messages remain pending               | Minute scheduler, workers, global switches, and schedule Slack settings     |
| Test form succeeds but no message arrives | Delivery history; tests need workers and expire after ten minutes           |
| Deliveries stay enqueued                  | Queue latency and worker health; minute maintenance recovers expired claims |
| Schedule is waiting for maintenance       | Minute job is running                                                       |
| Upcoming coverage stops too soon          | Daily projection job and reported schedule failures                         |
| Failed Slack messages                     | Delivery history error; fix the cause before retrying                       |

Unprocessed delivery claims expire after 30 minutes, so keep queue latency below that. Subscribe to `.munawaba` events through `ActiveSupport::Notifications` for enqueue, maintenance, timing, and transport problems.

## Upgrading

Update the gem and copy new engine migrations:

```sh
bundle update munawaba
bin/rails generate munawaba:install --no-initializer
bin/rails db:migrate
```

For timezone-data changes, follow [timezone-data updates](#timezone-data-updates).
