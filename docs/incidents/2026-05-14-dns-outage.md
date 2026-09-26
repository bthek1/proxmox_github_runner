# Incident: GitHub Actions Runner DNS Outage

**Date:** 2026-05-14  
**Duration:** ~1.5 days (since 2026-05-13 ~06:09 UTC)  
**Severity:** High — all GitHub Actions jobs blocked  
**Status:** Resolved

---

## Summary

All four self-hosted GitHub Actions runners on the Proxmox LXC container (`gh-runner`, ID 111, `192.168.2.101`) were running but unable to connect to GitHub. Jobs queued but never executed. The root cause was a broken DNS configuration: Proxmox had written `nameserver 10.8.0.1` into `/etc/resolv.conf` on the container, pointing to a WireGuard VPN DNS server that was unreachable from the container network.

---

## Timeline

| Time (UTC)       | Event                                                                                                                                        |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-05-13 05:59 | All 4 runner services started (container boot or restart)                                                                                    |
| 2026-05-13 06:09 | First DNS-related connection errors logged: `Resource temporarily unavailable` against `pipelinesghubeus*.actions.githubusercontent.com:443` |
| 2026-05-13 06:40 | Retry errors continue — runners kept retrying but DNS never resolved                                                                         |
| 2026-05-14 17:23 | DNS fixed manually; all runners reconnected and picked up queued jobs within seconds                                                         |

---

## Root Cause

Proxmox sets the DNS server for LXC containers via the host node configuration and writes it into the container's `/etc/resolv.conf` with a `# --- BEGIN PVE --- / # --- END PVE ---` block.

The Proxmox host node had `10.8.0.1` configured as its DNS server (a WireGuard VPN gateway). This IP was propagated into the LXC container's `/etc/resolv.conf`. The container cannot reach `10.8.0.1` because the WireGuard tunnel does not bridge into the LXC network namespace.

```
# /etc/resolv.conf (broken state)
# --- BEGIN PVE ---
nameserver 10.8.0.1
# --- END PVE ---
```

Because `github.com` and `pipelinesghubeus*.actions.githubusercontent.com` could not be resolved, the runner processes received `Resource temporarily unavailable` on every outbound HTTPS connection attempt. The runner services appeared healthy (`active (running)`) but could not pick up any jobs.

---

## Detection

The issue was identified by:

1. Checking runner service status — all 4 services were `active (running)` with no recent log entries (journal showed no entries in the past hour).
2. Testing outbound HTTPS: `curl https://github.com` returned HTTP `000` (connection failure before TLS handshake).
3. Running `nslookup github.com` inside the container — DNS timed out against `10.8.0.1`.

---

## Fix Applied

Manually overwrite `/etc/resolv.conf` with reliable public DNS servers:

```bash
ssh root@192.168.2.101
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
```

All 4 runners reconnected to GitHub within seconds and immediately began processing queued jobs.

---

## Affected Runners

| Service                | Target                            | Status after fix                |
| ---------------------- | --------------------------------- | ------------------------------- |
| `proxmox-lxc-runner-0` | `bthek1/github_runner`            | Reconnected, Listening for Jobs |
| `proxmox-lxc-runner-1` | `bthek1/github_runner`            | Reconnected, Listening for Jobs |
| `proxmox-lxc-runner-2` | `Recovery-Metrics/RM_DRF_Project` | Reconnected, Listening for Jobs |
| `proxmox-lxc-runner-3` | `Recovery-Metrics/RM_DRF_Project` | Reconnected, Listening for Jobs |

---

## Prevention

**Status: implemented.** All three options below are now in place.

### Option A — Fix Proxmox node DNS (done)

The node's DNS no longer points at the VPN gateway. This propagates to every
LXC container on the node:

```bash
pvesh set /nodes/<node>/dns --dns1 1.1.1.1 --dns2 8.8.8.8
```

### Option B — Pin DNS per container in Terraform (done)

`terraform/lxc/main.tf` sets the container's own DNS servers, so the container
no longer inherits whatever the node happens to have:

```hcl
initialization {
  dns {
    servers = var.dns_servers   # ["1.1.1.1", "8.8.8.8"]
  }
}
```

This is an **in-place** container update, not a rebuild. Ansible additionally
keeps a known-good copy at `/etc/github-runner/resolv.conf.known-good`.

### Option C — Monitoring and self-repair (done)

`runner-health.timer` runs `/usr/local/bin/runner-health` every 5 minutes, and
2 minutes after boot — the window in which Proxmox rewrites `/etc/resolv.conf`.
It checks what jobs actually depend on rather than what `systemctl` reports:

1. `getent hosts github.com` — on failure, restores the known-good resolver
2. `curl https://api.github.com` — on recovery, restarts every runner service
3. Per-runner service liveness — restarts a stopped unit
4. Per-runner registration against the GitHub API — re-registers a dropped
   runner using the PAT at `/etc/github-runner/pat`
5. Disk headroom — triggers `runner-cleanup.service` above the threshold

Everything is logged under the `runner-health` journal tag:

```bash
just health       # run it now and see the verdict
just health-log   # recent history
```

**What would have happened on 2026-05-13:** step 1 fails at 06:09, the resolver
is restored, step 2 confirms recovery, all four runners restart and pick up
queued jobs. Total outage ~5 minutes instead of ~35 hours.

---

## Notes

- The runner services were `active (running)` throughout the outage — standard `systemctl status` would not reveal the problem.
- Proxmox silently overwrites `/etc/resolv.conf` on LXC container start using the node's DNS configuration.
- The WireGuard VPN (`10.8.0.1`) being set as the node DNS is likely a side-effect of a VPN client running on the Proxmox host.
