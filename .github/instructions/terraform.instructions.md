---
description: "Use when writing, reviewing, or editing Terraform (.tf) files for Proxmox. Covers naming conventions, variable patterns, provider config, and state backend requirements."
applyTo: "**/*.tf"
---

# Terraform Conventions

## Scope — what belongs in Terraform

Terraform owns **infrastructure only**: the container/VM, its CPU, RAM, swap,
disk, network, and DNS. Configuration *inside* a machine belongs to Ansible
(`ansible/roles/`), not to a provisioner. See
`.github/instructions/ansible.instructions.md`.

- Do **not** add software installation, service management, or registration
  logic to a `remote-exec` provisioner. This repo removed exactly that: one
  inline shell block reinstalled every GitHub runner on any token change, so an
  apply during CI killed live jobs and a mid-way failure left zero runners.
- A `local-exec` that invokes `ansible-playbook` is the supported bridge. Pass
  secrets through its `environment` block, never on the command line.
- When Terraform needs to hand values to Ansible, generate a `local_file` into
  `ansible/group_vars/` and gitignore it. `terraform.tfvars` stays the single
  source of truth; nothing is duplicated by hand.

## Check the plan for replacement, always

Some attributes are ForceNew in `bpg/proxmox` and will **destroy and recreate**
a container that has live state on it (`datastore_id` is the known example).
Before applying any change to an existing container, confirm the plan says
`will be updated in-place` and not `must be replaced`:

```bash
terraform -chdir=terraform/lxc plan | grep -E "will be|must be|forces replacement"
```

If an attribute is ForceNew but the change is genuinely wanted, make it
out-of-band on the Proxmox side and reconcile with
`terraform apply -refresh-only`, then update `terraform.tfvars` to match.

## Naming
- All resource names, variable names, and output names use `snake_case`
- Resource names describe the thing, not the type: `web_server` not `proxmox_vm_web`
- Locals are prefixed with their purpose: `local.vm_tags`, `local.network_config`

## Variables
- Every configurable value must be a variable — no hardcoded IPs, node names, or IDs in resource blocks
- Sensitive variables (tokens, passwords) must set `sensitive = true`
- Variables without defaults are required inputs — only omit defaults for values that must be explicitly set per environment (e.g. `vm_id`, `proxmox_endpoint`)
- Use `description` on every variable and output

## Credentials / Secrets
- Never hardcode credentials in `.tf` files
- Use `TF_VAR_*` environment variables or a gitignored `terraform.tfvars` / `*.auto.tfvars` file
- `*.tfvars` and `*.tfstate*` must remain in `.gitignore`

## Provider: bpg/proxmox
- Preferred provider: [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- Credentials via env vars: `PROXMOX_VE_USERNAME`, `PROXMOX_VE_PASSWORD`, or `PROXMOX_VE_API_TOKEN`
- Pin to a minor version: `~> 0.75`

## File Layout (under `terraform/`)
| File | Purpose |
|------|---------|
| `provider.tf` | Provider + required_providers block |
| `versions.tf` | `terraform {}` block with `required_version` |
| `main.tf` | Primary resources |
| `variables.tf` | All input variables |
| `outputs.tf` | All outputs |
| `locals.tf` | Computed locals (optional) |

## State Backend
- Default: local state is fine for experiments
- For shared/persistent infra, configure a remote backend (e.g. S3, Terraform Cloud) in `provider.tf` or a separate `backend.tf`
- Never commit `terraform.tfstate` or `terraform.tfstate.backup`

## Provisioner triggers
- `null_resource` triggers must be *meaningful*. Short-lived values (e.g. GitHub
  registration tokens, which expire in an hour) force a pointless re-run on
  every apply — hash presence (`!= "" ? "yes" : "no"`) instead of the value.
- When a provisioner runs external code (an Ansible role), fingerprint that code
  so edits to it actually trigger a re-run:
  `sha256(join("", [for f in sort(fileset(dir, "**")) : filesha256(...)]))`.
  Exclude anything Terraform itself generates into that directory, or the
  resource depends on its own output.

## Formatting
- Run `terraform fmt -recursive` before committing
- Run `terraform validate` after any structural change
- Run `terraform plan` and read it before every apply — never skip it
