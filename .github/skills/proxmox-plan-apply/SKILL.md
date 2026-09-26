---
name: proxmox-plan-apply
description: "Run terraform plan and terraform apply for Proxmox infrastructure. Use when deploying, updating, or applying changes to Proxmox VMs or resources. Handles env var setup, plan review, and conditional apply."
argument-hint: "Optional: terraform directory or target resource (e.g. 'terraform/' or '-target=proxmox_virtual_environment_vm.web')"
---

# Proxmox Plan & Apply

Runs `terraform plan` followed by an optional `terraform apply` against the Proxmox provider.

## When to Use
- Deploying new Proxmox VMs or resources
- Applying configuration changes to existing infrastructure
- Reviewing what changes Terraform would make before applying

## Prerequisites

The following environment variables must be set before running:

```bash
# Option A — username/password
export PROXMOX_VE_USERNAME="root@pam"
export PROXMOX_VE_PASSWORD="<password>"
export PROXMOX_VE_ENDPOINT="https://<proxmox-host>:8006/"

# Option B — API token
export PROXMOX_VE_API_TOKEN="<user>@pam!<token-id>=<uuid>"
export PROXMOX_VE_ENDPOINT="https://<proxmox-host>:8006/"
```

> These are never stored in `.tf` files. Set them in your shell or a `.envrc` (gitignored secrets block).

## Procedure

1. **Check prerequisites** — confirm the env vars above are set and the `terraform/` directory exists
2. **Init** (if needed) — run [init script](./scripts/plan-apply.sh) with `init` argument, or check if `.terraform/` exists
3. **Plan** — run `terraform plan -out=tfplan` and display the output for review
4. **Confirm** — ask the user to confirm before applying (skip if user passed `--auto-approve`)
5. **Apply** — run `terraform apply tfplan`
6. **Show outputs** — run `terraform output` and display results

## Running the Script

```bash
# Plan only
.github/skills/proxmox-plan-apply/scripts/plan-apply.sh plan [terraform-dir] [extra tf flags]

# Plan + apply (with confirmation prompt)
.github/skills/proxmox-plan-apply/scripts/plan-apply.sh apply [terraform-dir] [extra tf flags]
```

## Safety
- Always show the plan output before applying
- Never auto-apply without user confirmation unless explicitly asked
- Destroy operations (`terraform destroy`) are out of scope for this skill — run manually
- **Check the plan for `must be replaced`.** Some `bpg/proxmox` attributes are
  ForceNew (notably `datastore_id`) and will destroy a container that has live
  state on it. Stop and ask rather than applying.

## In this repo, apply does more than Terraform

`terraform apply` here also triggers `null_resource.runner_provision`, which runs
`ansible-playbook` against the live runner container. Consequences:

- The apply reconfigures a machine that may be executing CI jobs. The Ansible
  role drains each runner first, so nothing is killed — but the apply can block
  for up to 30 minutes waiting on a long job.
- Ansible task output is **suppressed** in the apply log, because the
  provisioner's `environment` carries sensitive values. Verify the outcome from
  the host afterwards: `just health`, `just runner-services`, `just runners`.
- If only in-container configuration changed, prefer `just converge` — it needs
  no Proxmox credentials and no registration tokens.

See [RUNNER_OPERATIONS.md](../../../docs/RUNNER_OPERATIONS.md).
