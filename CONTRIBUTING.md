# Contributing

Keep changes focused on on-call scheduling. Explain the problem your change solves and include the checks you ran.

## Setup

Use the Ruby version in `mise.toml` and install Chrome for browser tests. From the repository root:

```sh
docker compose up -d
docker compose exec postgres createdb -U munawaba munawaba_test
bundle install
bin/browser-setup
```

Tests use `munawaba_test` on the local PostgreSQL service. Set `DATABASE_URL` to use another dedicated test database. Migration, concurrency, and installation tests create disposable databases and need `CREATEDB`; the extension privilege test also needs `CREATEROLE`.

## Local demo

The demo app includes sample schedules and people, with authentication and outbound Slack disabled.

```sh
cd test/dummy
bin/rails db:migrate
bin/rails db:seed
bin/rails server -p 3100
```

Open `http://localhost:3100/on-call`.

## Tests and build

From the repository root:

```sh
bin/test
bundle exec rake rubocop
bundle exec rake build
```

`bundle exec rake` runs tests and RuboCop together. The build writes `pkg/munawaba-VERSION.gem`.

Add tests for the behavior you change. Pay particular attention to DST handoffs, changes to the current assignee, stale previews, concurrent commands, and notification retries. Scheduling tests must use PostgreSQL so they exercise the locks and constraints.

The suite covers scheduling and lifecycle rules, database installation and upgrades, host integration, durable notifications, maintenance, keyboard and no-JavaScript flows, both themes, mobile layouts, and accessibility.

## Schema

Roster positions and memberships are unique. A schedule has at most one live shift for a logical boundary, its live shifts cannot overlap, and each shift has at most one active override. The deferrable overlap constraint lets timing repair move neighboring handoffs together without failing on temporary overlap inside the transaction.

Notification event keys prevent duplicate deliveries, and each failed delivery can have one manual retry successor. Notification context is limited to a 16 KiB JSON object. Activity metadata is limited to a 128 KiB JSON object.

Schema changes need migration and dump/load tests. Migrations enable `btree_gist` for overlap constraints and leave the shared extension installed on rollback.

## Performance checks

Run this after changing queries or background jobs:

```sh
bundle exec rake performance
```

The task captures query plans and measures HTTP and job budgets against large fixtures. The checks live in [test/performance](test/performance), with query capture in [test/database/capture_query_plans.rb](test/database/capture_query_plans.rb).

The runners **drop and recreate** their databases and need `CREATEDB`. Use dedicated databases whose names match these suffixes:

| Environment variable         | Purpose                           | Required suffix |
| ---------------------------- | --------------------------------- | --------------- |
| `MUNAWABA_PLAN_DATABASE_URL` | Query plans and HTTP measurements | `_query_plans`  |
| `MUNAWABA_JOB_DATABASE_URL`  | Job measurements                  | `_performance`  |

The job URL also accepts `MUNAWABA_PERFORMANCE_DATABASE_URL`. Local defaults use the PostgreSQL service at `127.0.0.1:55432`. Reports are written to `tmp/performance/` and uploaded with browser screenshots by the primary CI job.

## Compatibility and CI

| Ruby | Rails | PostgreSQL     | Status        |
| ---- | ----- | -------------- | ------------- |
| 4.0  | 8.1   | 15, 16, 17, 18 | Required      |
| 3.4  | 8.1   | 17             | Required      |
| 3.3  | 8.0   | 17             | Compatibility |
| 3.2  | 7.2   | 17             | Compatibility |

Compatibility lanes are nonblocking and outside the supported baseline. The Ruby 4.0/PostgreSQL 17 lane also runs installation, browser, performance, security, and package checks. A separate job runs RuboCop and verifies generated Appraisal Gemfiles. See the [CI workflow](.github/workflows/ci.yml) for commands.

## Security checks

```sh
bundle exec brakeman --force-scan --rails8 --path . --skip-files test/ --no-pager
bundle exec brakeman --rails8 --path test/dummy --no-pager
bundle exec bundle-audit check --update
```

Report vulnerabilities through the contact in [Security](SECURITY.md).

## Changes and reviews

Run `bundle exec appraisal generate` after editing `Appraisals` or `Gemfile`, then test each affected lane with its matching Ruby. Update the [README](README.md) or [usage guide](docs/usage.md) when behavior changes, include validation results in the pull request, and leave generated reports in `tmp/`.
