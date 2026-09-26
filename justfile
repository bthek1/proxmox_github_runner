# justfile — Terraform commands for Proxmox LXC management
# Usage: just <recipe>  (run `just` or `just -l` to see all recipes)

tf_dir := "terraform/lxc"

# List all available recipes
[group('meta')]
default:
	@just --list


# ── Init ────────────────────────────────────────────────────────────────────

# Initialise Terraform (download providers)
[group('init')]
init:
	terraform -chdir={{tf_dir}} init

# Upgrade providers to latest allowed versions
[group('init')]
upgrade:
	terraform -chdir={{tf_dir}} init -upgrade

# ── Plan / Apply / Destroy ───────────────────────────────────────────────────

# Show execution plan (infra only, no runner re-provision)
[group('plan/apply/destroy')]
plan:
	source .envrc && terraform -chdir={{tf_dir}} plan -var-file=terraform.tfvars

# Apply changes (prompts for confirmation; infra only)
[group('plan/apply/destroy')]
apply:
	source .envrc && terraform -chdir={{tf_dir}} apply -var-file=terraform.tfvars

# Apply without interactive prompt (infra only)
[group('plan/apply/destroy')]
apply-auto:
	source .envrc && terraform -chdir={{tf_dir}} apply -var-file=terraform.tfvars -auto-approve

# Converge runners via Ansible — no tokens needed, safe to run during CI
[group('runner')]
converge:
	#!/usr/bin/env bash
	set -euo pipefail
	export ANSIBLE_CONFIG=ansible/ansible.cfg
	export GH_RUNNER_PAT="${GH_RUNNER_PAT:-}"
	ansible-playbook -i ansible/inventory.ini -l gh_runner ansible/playbooks/runners.yml

# Dry-run the Ansible convergence (no changes made)
[group('runner')]
converge-check:
	#!/usr/bin/env bash
	set -euo pipefail
	export ANSIBLE_CONFIG=ansible/ansible.cfg
	ansible-playbook -i ansible/inventory.ini -l gh_runner ansible/playbooks/runners.yml --check --diff

# Mint fresh registration tokens (only needed for NEW runners) and converge
[group('runner')]
converge-tokens:
	#!/usr/bin/env bash
	set -euo pipefail
	export ANSIBLE_CONFIG=ansible/ansible.cfg
	export GH_RUNNER_TOKENS="$(just _tokens)"
	export GH_RUNNER_PAT="${GH_RUNNER_PAT:-}"
	ansible-playbook -i ansible/inventory.ini -l gh_runner ansible/playbooks/runners.yml

# Mint one registration token per target, comma-separated, in tfvars order
[group('runner')]
[private]
_tokens:
	#!/usr/bin/env bash
	set -euo pipefail
	TOKEN1=$(gh api --method POST -H "Accept: application/vnd.github+json" \
	    /repos/bthek1/proxmox_github_runner/actions/runners/registration-token --jq '.token')
	TOKEN2=$(gh api --method POST -H "Accept: application/vnd.github+json" \
	    /repos/Recovery-Metrics/RM_DRF_Project/actions/runners/registration-token --jq '.token')
	TOKEN3=$(gh api --method POST -H "Accept: application/vnd.github+json" \
	    /repos/bthek1/Stock_Market/actions/runners/registration-token --jq '.token')
	printf '%s,%s,%s' "${TOKEN1}" "${TOKEN2}" "${TOKEN3}"

# Plan infra + runner provisioning (tokens minted only if you have new runners)
[group('plan/apply/destroy')]
runner-plan:
	#!/usr/bin/env bash
	set -euo pipefail
	source .envrc
	export TF_VAR_github_runner_tokens="${TF_VAR_github_runner_tokens:-}"
	terraform -chdir={{tf_dir}} plan -out=tfplan

# Apply infra, then converge the runners via Ansible
[group('plan/apply/destroy')]
runner-apply:
	#!/usr/bin/env bash
	set -euo pipefail
	source .envrc
	export TF_VAR_github_runner_tokens="${TF_VAR_github_runner_tokens:-$(just _tokens)}"
	terraform -chdir={{tf_dir}} plan -out=tfplan
	terraform -chdir={{tf_dir}} apply tfplan

# Destroy all resources (prompts for confirmation)
[group('plan/apply/destroy')]
destroy:
	source .envrc && terraform -chdir={{tf_dir}} destroy -var-file=terraform.tfvars

# Destroy without interactive prompt
[group('plan/apply/destroy')]
destroy-auto:
	source .envrc && terraform -chdir={{tf_dir}} destroy -var-file=terraform.tfvars -auto-approve

# ── Inspect ──────────────────────────────────────────────────────────────────

# Show current Terraform state
[group('inspect')]
show:
	terraform -chdir={{tf_dir}} show

# List resources in state
[group('inspect')]
state:
	terraform -chdir={{tf_dir}} state list

# Show outputs
[group('inspect')]
output:
	terraform -chdir={{tf_dir}} output

# Check runner status on GitHub for both repos
[group('inspect')]
runners:
	gh api /repos/bthek1/proxmox_github_runner/actions/runners --jq '.runners[] | {name, status}'
	gh api /repos/Recovery-Metrics/RM_DRF_Project/actions/runners --jq '.runners[] | {name, status}'
	gh api /repos/bthek1/Stock_Market/actions/runners --jq '.runners[] | {name, status}'

# Run the health check on the container right now and show its verdict
[group('inspect')]
health:
	ssh -i ~/.ssh/id_ed25519 root@192.168.2.111 "/usr/local/bin/runner-health"

# Recent health-check and cleanup history from the container's journal
[group('inspect')]
health-log:
	ssh -i ~/.ssh/id_ed25519 root@192.168.2.111 \
	    "journalctl -t runner-health -t runner-cleanup --no-pager -n 80"

# Show the health and cleanup timer schedules
[group('inspect')]
timers:
	ssh -i ~/.ssh/id_ed25519 root@192.168.2.111 \
	    "systemctl list-timers 'runner-*' --no-pager"

# Run disk cleanup on the container right now
[group('inspect')]
cleanup:
	ssh -i ~/.ssh/id_ed25519 root@192.168.2.111 "/usr/local/bin/runner-cleanup"

# Check runner systemd services on the container
[group('inspect')]
runner-services:
	ssh -i ~/.ssh/id_ed25519 root@192.168.2.111 "systemctl list-units 'actions.runner.*' --no-pager"

# Show the runner's root disk usage and backing Proxmox storage
[group('inspect')]
runner-disk:
	ssh -i ~/.ssh/id_ed25519 root@192.168.2.111 "df -h /"

# SSH into the GitHub runner container
[group('inspect')]
ssh:
	ssh -i ~/.ssh/id_ed25519 root@192.168.2.111

# ── Validate / Format ────────────────────────────────────────────────────────

# Validate configuration files
[group('validate/format')]
validate:
	terraform -chdir={{tf_dir}} validate

# Format all .tf files
[group('validate/format')]
fmt:
	terraform -chdir={{tf_dir}} fmt -recursive

# Check formatting without writing (CI-safe)
[group('validate/format')]
fmt-check:
	terraform -chdir={{tf_dir}} fmt -recursive -check

# ── Convenience ──────────────────────────────────────────────────────────────

# init → validate → plan
[group('convenience')]
check: init validate plan

# init → validate → apply-auto (infra only, no runner re-provision)
[group('convenience')]
deploy: init validate apply-auto
