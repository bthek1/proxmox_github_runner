# GitHub Actions Self-Hosted Runner on Proxmox LXC

Provision a Proxmox LXC container using Terraform and automatically install and
register a GitHub Actions self-hosted runner inside it.

---

## Prerequisites

- Proxmox VE 7.x or 8.x with the bpg/proxmox provider accessible via API token or username/password
- Terraform ≥ 1.5
- SSH key at `~/.ssh/id_ed25519` injected into the container's root account
- GitHub PAT with `repo` scope (to generate a runner registration token)
- Ubuntu 24.04 LXC template present in Proxmox local storage
- `gh` CLI (optional, for one-step token generation)

---

## Credentials — `.envrc`

Copy your Proxmox credentials into `.envrc` (already gitignored) and source it before any Terraform command:

```bash
# .envrc
export TF_VAR_proxmox_endpoint="https://192.168.2.70:8006/"
export TF_VAR_proxmox_username="root@pam"
export TF_VAR_proxmox_password="<password>"
# or use an API token instead:
# export TF_VAR_proxmox_api_token="user@pam!token-id=<uuid>"
```

```bash
source .envrc
```

---

## How to get a runner registration token

**GitHub CLI (recommended):**

```bash
gh api --method POST \
  -H "Accept: application/vnd.github+json" \
  /repos/<owner>/<repo>/actions/runners/registration-token \
  --jq '.token'
```

**GitHub UI:**

1. Go to your repository → Settings → Actions → Runners → **New self-hosted runner**
2. Copy the token shown in the **Configure** step (it starts with `A...`)

**GitHub API:**

```bash
curl -s -X POST \
  -H "Authorization: Bearer <YOUR_PAT>" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/<owner>/<repo>/actions/runners/registration-token \
  | jq -r .token
```

Tokens expire after **1 hour** — generate one immediately before running `terraform apply`.

---

## Deploy

```bash
# 1. Source Proxmox credentials
source .envrc

# 2. Optional but recommended — lets the runner host recover unattended
export TF_VAR_github_pat="ghp_..."      # repo + workflow scope

# 3. Apply infrastructure, then converge the runners
just runner-apply
```

Registration tokens are only required for runners that do not exist yet (a new
target, a higher `github_runner_parallel`, or a rebuilt container).
`just runner-apply` mints them automatically; everyday changes need none:

```bash
just converge          # converge runners via Ansible, no tokens, safe during CI
just converge-check    # dry run
```

Edit `terraform/lxc/terraform.tfvars` first (copy from `terraform.tfvars.example`)
to set your `github_runner_targets`, container ID, IP address, and other values.

---

## How it fits together

| Layer         | Owns                                                                     |
| ------------- | ------------------------------------------------------------------------ |
| **Terraform** | The LXC container: CPU, RAM, disk, network, **and pinned DNS**            |
| **Ansible**   | Everything inside it: runner binaries, registration, systemd, health, GC  |

`terraform.tfvars` stays the single source of truth — Terraform projects the
runner settings into `ansible/group_vars/gh_runner.yml` (generated, gitignored)
which Ansible auto-loads, so `just converge` and `just runner-apply` agree.

Convergence is idempotent and rolling: each runner is evaluated independently,
and any runner executing a job is drained before it is touched. A failure costs
one runner, not the fleet.

---

## Staying up without you

Two systemd timers run inside the container:

```bash
just health       # run the health check now, see its verdict
just health-log   # recent health + cleanup history from the journal
just timers       # when the timers next fire
just cleanup      # reclaim disk space now
```

**`runner-health`** (every 5 min, and 2 min after boot) checks the path jobs
actually depend on and repairs what it can:

1. Name resolution → restores the pinned `/etc/resolv.conf`
2. GitHub API reachability → restarts every runner once connectivity returns
3. Per-runner liveness → restarts a stopped service
4. Per-runner registration → re-registers a runner GitHub dropped (needs the PAT)
5. Disk headroom → triggers cleanup before a full disk starts breaking jobs

This exists because on 2026-05-13 all runners sat green for ~1.5 days while DNS
pointed at an unreachable VPN gateway — `systemctl status` was clean throughout.
See [docs/incidents/2026-05-14-dns-outage.md](docs/incidents/2026-05-14-dns-outage.md).

**`runner-cleanup`** (daily) prunes stale `_work` directories, `_diag` logs, the
journal, and apt/pip/npm/docker caches, escalating to aggressive pruning above
`disk_warn_percent`. It skips any runner that is executing a job, and exits
non-zero with a loud journal entry if it still cannot get below the threshold —
that is the signal to grow the disk or reduce `github_runner_parallel`.

---

## Key variables (`terraform.tfvars`)

| Variable                | Description                              | Default                             |
| ----------------------- | ---------------------------------------- | ----------------------------------- |
| `container_id`          | Proxmox VMID                             | —                                   |
| `container_hostname`    | Container hostname                       | —                                   |
| `network_ip`            | Static IP in CIDR or `dhcp` (convention: last octet matches the VMID, e.g. VMID `111` → `192.168.2.111/24`) | `dhcp`                              |
| `network_gateway`       | Default gateway (static only)            | `""`                                |
| `datastore_id`          | Proxmox storage for the root disk. Live runner uses `nvme4tb-lvm` (4TB NVMe SSD). Changing this **recreates the container** — see AGENTS.md → Storage | `local-lvm`                         |
| `disk_size`             | Root disk size in GB                     | `8` (live runner: `64`)             |
| `github_runner_targets` | List of repo/org URLs to register against | —                                  |
| `github_runner_name`    | Display name in GitHub UI                | `proxmox-lxc-runner`                |
| `github_runner_labels`  | Runner labels list                       | `["self-hosted","linux","proxmox"]` |
| `github_runner_user`    | OS user that runs the service            | `runner`                            |
| `github_runner_version` | Runner binary version                    | `2.316.1`                           |
| `github_runner_parallel`| Runner instances per target              | `2` (live runner: `3`)              |
| `github_pat`            | PAT for unattended self re-registration  | `""` (recovery needs a human)       |
| `dns_servers`           | DNS pinned into the container — see DNS below | `["1.1.1.1","8.8.8.8"]`        |
| `health_check_interval` | How often `runner-health` runs           | `5min`                              |
| `cleanup_schedule`      | When `runner-cleanup` runs               | `daily`                             |
| `work_dir_retention_days`| Age at which `_work` dirs are pruned    | `7`                                 |
| `disk_warn_percent`     | Usage above which cleanup gets aggressive| `80`                                |

---

## Just recipes

```bash
just init             # terraform init
just plan             # terraform plan
just apply            # terraform apply (interactive, infra only)
just deploy           # init → validate → apply-auto (infra only)
just runner-apply     # apply infra, then converge runners
just converge         # converge runners only — no tokens, safe during CI
just converge-check   # dry run the convergence
just converge-tokens  # mint fresh tokens and converge (for NEW runners)
just health           # run the on-box health check now
just health-log       # recent health + cleanup journal entries
just timers           # health/cleanup timer schedules
just cleanup          # reclaim disk on the container now
just runners          # runner status on GitHub
just destroy          # terraform destroy
just fmt              # format all .tf files
```

---

## Verify

After a successful apply, the runner appears in:

> Repository → Settings → Actions → Runners

It should show as **Idle** with the labels defined in `github_runner_labels`.

You can also SSH in to check the service status:

```bash
ssh root@$(cd terraform/lxc && terraform output -raw runner_ip)
systemctl status "actions.runner.*"
```

---

## Destroy

```bash
just destroy
```

This tears down the LXC container. The runner will appear offline in GitHub —
remove it manually from Settings → Actions → Runners if needed.

---

## Re-registration

With `github_pat` set, this is automatic: `runner-health` notices a runner
GitHub no longer lists, mints its own registration token, and re-registers it
within five minutes.

Without a PAT, do it by hand:

```bash
just converge-tokens
```

---

## DNS

`dns_servers` is pinned via the container's Proxmox DNS setting rather than left
to the node. This is deliberate — Proxmox rewrites the container's
`/etc/resolv.conf` from the **node's** DNS on every start, which is exactly how
the 2026-05-13 outage happened. Changing it is an in-place container update, not
a rebuild.
