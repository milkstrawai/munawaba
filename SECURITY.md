# Security

## Reporting a vulnerability

Report vulnerabilities privately to [the maintainer](mailto:aliosm1997@gmail.com). Include the affected version, impact, and a minimal reproduction. Omit webhook URLs, encryption keys, and session data.

## Access and credentials

Configure authentication and authorization before mounting the dashboard for your team. The [access reference](docs/usage.md#access) describes the capabilities, including actions that affect several schedules. Controller callbacks govern dashboard requests; call `Munawaba::Commands` from trusted application code.

For Slack encryption and delivery troubleshooting, see [Slack notifications](docs/usage.md#slack-notifications).

## Checks

See [contributor security checks](CONTRIBUTING.md#security-checks) for static analysis and dependency auditing.
