# Runner Operations Runbook

How to diagnose and recover the self-hosted GitHub Actions runner fleet on the
Proxmox LXC container `gh-runner` (VMID `111`, `192.168.2.111`).

For the architecture, see [../README.md](../README.md). For agent-facing rules,
see [../AGENTS.md](../AGENTS.md).

---

## The fleet at a glance

| Property        | Value                                                      |
| --------------- | ---------------------------------------------------------- |
| Container       | VMID `111`, hostname `gh-runner`, `192.168.2.111/24`       |
| Resources       | 4 cores, 8 GB RAM, 4 GB swap, 64 GB on `nvme4tb-lvm`       |
| Runners         | 9 — three per target, `proxmox-lxc-runner-0` … `-8`        |
| Runner user     | `runner`, dirs `/home/runner/actions-runner-<idx>`         |
| Labels          | `self-hosted, linux, proxmox, ubuntu-24.04`                 |

| Index | Target                                     |
| ----- | ------------------------------------------ |
| 0–2   | `bthek1/proxmox_github_runner`             |
| 3–5   | `Recovery-Metrics/RM_DRF_Project`          |
| 6–8   | `bthek1/Stock_Market`                      |

---

## First response: one command

```bash
just health
```

Exit `0` means connectivity, every service, and (with a PAT) every registration
are fine. Exit non-zero prints what it could not fix. This runs automatically
every 5 minutes; you are reading the same verdict it logs.

Then widen out:

```bash
just health-log        # health + cleanup history from the journal
just runner-services   # all 9 systemd units
just runners           # what GitHub thinks, per target
just timers            # are the timers even running?
just runner-disk       # disk headroom
```

---

## Symptom → cause → fix

### Jobs queue but never start; runners show Idle/online

Most likely **DNS**, which is the failure mode that caused the
[2026-05-14 outage](incidents/2026-05-14-dns-outage.md). The services stay
`active (running)` and the journal goes quiet.

```bash
just ssh
getent hosts github.com          # fails?
curl -sf -o /dev/null https://api.github.com; echo $?
cat /etc/resolv.conf             # PVE block pointing somewhere unreachable?
```

`runner-health` repairs this within 5 minutes by restoring
`/etc/github-runner/resolv.conf.known-good` and restarting the runners. To force
it now: `just health`.

If it keeps coming back, the **Proxmox node's** DNS is wrong and is being
propagated on every container start:

```bash
ssh proxmox "pvesh get /nodes/bthek1/dns"
ssh proxmox "sudo pvesh set /nodes/bthek1/dns --dns1 1.1.1.1 --dns2 8.8.8.8"
```

### Runners show Offline in GitHub

```bash
just runner-services     # are the units running locally?
```

- **Units running, GitHub says offline** → connectivity. See the section above.
- **Units dead** → `runner-health` restarts them automatically. If a restart
  does not take, it re-registers (needs `github_pat`). Force with `just health`.
- **GitHub no longer lists the runner at all** → it was removed server-side.
  With a PAT this self-repairs; without one, run `just converge-tokens`.

### Jobs fail with no space left / confusing unrelated errors

```bash
just runner-disk
just cleanup             # prune now
just health-log          # what did cleanup manage to reclaim?
```

`runner-cleanup` runs nightly: stale `_work` dirs (>7 days), `_diag` logs, the
journal, and apt/pip/npm/docker caches. Above 80% it escalates and ignores
retention entirely. It **skips any runner executing a job**.

If cleanup exits non-zero saying it still cannot get below the threshold, that is
the signal to act structurally: grow `disk_size` in `terraform.tfvars`, or lower
`github_runner_parallel`.

### Jobs are slow, or the container is thrashing

Nine concurrent runners share 4 cores and 8 GB RAM — 2.25× oversubscribed on CPU.

```bash
just ssh
uptime; free -m
```

Either lower `github_runner_parallel` or raise `cpu_cores` / `memory_mb` in
`terraform.tfvars`, then `just runner-apply`. Setting `runner_memory_max`
(e.g. `2G`) makes the OOM killer take the runaway job instead of the runner
service supervising it.

### A runner is stuck on a job that will never finish

Drain waits up to 30 minutes, so convergence will block on it. Confirm it is
genuinely stuck, then kill the worker — the listener will recover:

```bash
just ssh
ps -o pid,etime,args -p $(pgrep -dx, Runner.Worker)
kill <pid>               # cancel the job in the GitHub UI first if possible
```

### `terraform plan` wants to replace the container

**Stop.** That destroys all nine runners. Almost always `datastore_id`, which is
ForceNew. Move the disk out-of-band in Proxmox, reconcile with
`terraform apply -refresh-only`, *then* update `terraform.tfvars`. See
[../AGENTS.md](../AGENTS.md) → Storage.

### `terraform plan` shows 1 to add / 1 to destroy and nothing else

That is `null_resource.runner_provision` re-triggering because the Ansible role
changed — the code-fingerprint trigger doing its job. Applying just re-runs the
playbook, which is idempotent. Harmless.

---

## Recovery procedures

### Rebuild a single runner

Delete its directory and converge; the role treats a missing runner as one that
needs registration. Needs a token for that target, or a PAT.

```bash
just ssh
/usr/local/bin/gh-runner-drain /home/runner/actions-runner-4 1800
cd /home/runner/actions-runner-4 && ./svc.sh uninstall
rm -rf /home/runner/actions-runner-4
exit
just converge-tokens
```

### Rebuild the whole container

```bash
source .envrc
export TF_VAR_github_pat="ghp_..."
just destroy          # removes CT 111
just runner-apply     # recreates and re-registers everything
```

Old runners linger as Offline in each repo's Settings → Actions → Runners.
With a PAT the role deregisters them; otherwise remove them by hand.

### Change how many runners per target

Edit `github_runner_parallel` in `terraform.tfvars`, then:

```bash
just runner-apply
```

Lowering it drains, deregisters, and removes the orphans. Raising it needs
tokens (or a PAT).

---

## What runs on the box

| Path                                            | Purpose                                     |
| ----------------------------------------------- | ------------------------------------------- |
| `/usr/local/bin/runner-health`                  | Health check and self-repair (5 min timer)   |
| `/usr/local/bin/runner-cleanup`                 | Disk reclamation (nightly timer)             |
| `/usr/local/bin/gh-runner-token`                | Mints registration/removal tokens from PAT   |
| `/usr/local/bin/gh-runner-drain`                | Blocks until a runner finishes its job       |
| `/etc/github-runner/pat`                        | PAT, `0600` — enables unattended recovery    |
| `/etc/github-runner/resolv.conf.known-good`     | Resolver the health check restores           |
| `/etc/systemd/system/actions.runner.*.d/`       | `Restart=always`, `OOMPolicy=continue`       |
| `/var/lib/github-runner/last-healthy`           | Timestamp of the last clean health check     |

Journal tags: `runner-health`, `runner-cleanup`.

```bash
just ssh
journalctl -t runner-health -f            # watch live
journalctl -t runner-cleanup --since -7d  # what has been reclaimed
```

---

## Known limitations

- **Single point of failure.** All nine runners live on one container on one
  Proxmox node. There is no failover; a node reboot stops all CI.
- **No PAT means no unattended recovery.** Without `github_pat`, the health
  check can restart a dead service but cannot re-register a runner GitHub has
  dropped. It says so explicitly in its log line.
- **No external alerting.** Failures land in the container's journal. Nothing
  pages you — `runner-health` exits non-zero and `runner-cleanup` logs at
  `warning`, which is enough to hook into a log shipper, but none is configured.
- **No Proxmox backup job on CT 111.** Recovery is a rebuild, not a restore.
- **CPU oversubscribed 2.25×** (9 runners, 4 cores) — deliberate, accepted.
