---
description: "Use when writing, reviewing, or editing Ansible playbooks, roles, or templates in this repo. Covers the Terraform/Ansible ownership boundary, idempotency and drain requirements, secret handling, and known gotchas on the runner host."
applyTo: "ansible/**"
---

# Ansible Conventions

## Ownership boundary — read this first

**Terraform owns the LXC container. Ansible owns everything inside it.**

| Layer     | Owns                                                                    |
| --------- | ----------------------------------------------------------------------- |
| Terraform | CPU, RAM, swap, disk, network, container DNS, start-on-boot             |
| Ansible   | Runner binaries, registration, systemd units, health check, disk cleanup |

Never put in-container configuration into a Terraform `remote-exec` provisioner.
That is what this repo moved away from: a single inline shell block tore down
*every* runner on any token change, so an apply during CI killed live jobs and a
failure part-way through left the host with zero runners.

## Variables come from Terraform

`ansible/group_vars/gh_runner.yml` is **generated** by
`local_file.ansible_group_vars` in `terraform/lxc/main.tf` from
`terraform.tfvars`, and is gitignored.

- **Never hand-edit it** — it is overwritten on the next plan/apply.
- To change runner configuration, edit `terraform/lxc/terraform.tfvars` and add
  the variable to the `yamlencode({...})` block in `main.tf`.
- Role defaults in `roles/github_runner/defaults/main.yml` are the fallback for
  standalone runs; keep them in sync with the Terraform variable defaults.

## Idempotency is mandatory

Every task must be safe to re-run, because `just converge` is expected to run
during CI with live jobs in flight.

- A runner that is already registered against the right target with an active
  service must produce **no change**. `tasks/instance.yml` checks `.runner`
  (gitHubUrl + agentName) and `.service` before doing anything.
- Prove it: run the playbook twice. The second run must report `changed=0`
  (or only the tasks whose templates you actually edited) and every runner must
  log `already converged`.
- Use `creates:`, `force: false`, and versioned filenames rather than
  unconditional downloads and extractions.
- `changed_when` / `failed_when` on every `command` task. A bare `command` that
  always reports changed breaks the idempotency check above.

## Never touch a busy runner

Before stopping, restarting, reconfiguring, or deleting anything under a runner
directory, drain it:

```yaml
- name: "{{ runner.name }} | wait for any in-flight job to finish"
  ansible.builtin.command:
    argv: ["{{ github_runner_bin_dir }}/gh-runner-drain", "{{ runner.dir }}", "{{ drain_timeout }}"]
  changed_when: false
```

`gh-runner-drain` blocks until no `Runner.Worker` process has its cwd inside
that directory. Passing a timeout of `0` turns it into a non-blocking "is this
runner busy?" probe, which is how `runner-cleanup` skips active runners.

## Failure isolation

Converge each runner in its own `include_tasks` iteration so one broken runner
costs one runner, not the fleet. Do not use `parallel()`-style fan-out that
aborts the play, and do not batch a fleet-wide stop before a fleet-wide start.

## Secrets

- Registration tokens and the PAT arrive via the environment
  (`GH_RUNNER_TOKENS`, `GH_RUNNER_PAT`), never via argv or a file in git —
  otherwise `ps` on the workstation exposes them.
- `no_log: true` on any task that receives a token or the PAT.
- The PAT is written to `/etc/github-runner/pat`, mode `0600`, root-owned.
- Tokens are only needed for runners that are **not yet registered**. A task
  that unconditionally requires a token is a bug — everyday convergence must
  work with `GH_RUNNER_TOKENS` empty.

## Known gotchas on the runner host

- **`.runner` has a UTF-8 BOM.** `from_json` rejects it; `jq` tolerates it.
  Always strip it first:
  `content | b64decode | regex_replace('^﻿', '') | from_json`
- **Runners self-update.** `github_runner_version` only controls the initial
  tarball download. The live host has self-updated well past it
  (`bin.2.337.0` against a pinned `2.316.1`). Never "correct" this drift by
  reinstalling — that throws away a working binary. Convergence deliberately
  leaves a registered, active runner alone.
- **`ansible.builtin.template` does not create parent directories.** systemd
  drop-in dirs (`/etc/systemd/system/<unit>.d/`) need an explicit
  `ansible.builtin.file: state=directory` task first.
- **Task ordering.** Anything writing into `/etc/github-runner` must come after
  the task that creates it. `dns.yml` depends on this.
- **Proxmox rewrites `/etc/resolv.conf`** from the *node's* DNS on every
  container start. See `docs/incidents/2026-05-14-dns-outage.md`.

## Style

- FQCN for every module: `ansible.builtin.copy`, not `copy`.
- Task names are prefixed with the thing they act on:
  `"{{ runner.name }} | register with GitHub"`.
- Explain *why* in comments, especially where a task exists because of a past
  incident. Link the incident doc.
- Run `ansible-playbook --syntax-check ansible/playbooks/runners.yml` after any
  structural change, and `just converge-check` for a dry run against the host.

## Verifying a change

```bash
just converge-check   # dry run, no changes
just converge         # apply; safe during CI
just converge         # run again — must be a near no-op
just health           # on-box health verdict
just runners          # GitHub-side status for all targets
```
