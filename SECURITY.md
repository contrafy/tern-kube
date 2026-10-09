# Security policy

## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting:
[Report a vulnerability](https://github.com/contrafy/tern-kube/security/advisories/new)
(Security tab, "Report a vulnerability"). Do not open a public issue.

Include the version (`version` in `plugin.toml` or `tern plugin
list`), Tern version, OS and architecture, your shell for guard issues, and
steps to reproduce. Never include real kubeconfigs, tokens or Secret data.

Fixes are released as a patch version and credited in the advisory unless
you prefer otherwise.

## Supported versions

Tern Kube is pre-1.0. Only the latest release and `master` receive security
fixes.

| Version | Supported |
| --- | --- |
| latest `0.y.z` release | yes |
| `master` | yes |
| older releases | no |

## Scope

What Tern Kube does and does not protect against, including the same-user
trust boundary and why the shell guard is advisory rather than admission
control, is in [docs/security-model.md](docs/security-model.md). Reports
that a same-user process can bypass the guard or `command kubectl` skips it
are expected behavior; reports that the guard or the approve block executes
something other than what was previewed and confirmed are in scope.
