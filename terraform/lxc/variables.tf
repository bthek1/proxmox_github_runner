# variables.tf — Input variables for the Proxmox LXC container

# ── Provider ────────────────────────────────────────────────────────────────

variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://proxmox.local:8006/"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox username, e.g. root@pam. Leave empty when using API token."
  type        = string
  default     = ""
}

variable "proxmox_password" {
  description = "Proxmox password. Leave empty when using API token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_api_token" {
  description = "Proxmox API token, e.g. user@pam!token-id=uuid. Leave empty when using username/password."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_insecure" {
  description = "Skip TLS certificate verification (useful for self-signed certs)."
  type        = bool
  default     = true
}

# ── Node ────────────────────────────────────────────────────────────────────

variable "proxmox_node" {
  description = "Proxmox node name where the container will be created."
  type        = string
}

# ── Container identity ───────────────────────────────────────────────────────

variable "container_id" {
  description = "Numeric VMID for the LXC container. Must be unique on the node."
  type        = number
}

variable "container_hostname" {
  description = "Hostname for the LXC container."
  type        = string
}

variable "container_description" {
  description = "Optional description shown in the Proxmox UI."
  type        = string
  default     = ""
}

variable "container_tags" {
  description = "List of tags to apply to the container."
  type        = list(string)
  default     = []
}

# ── Template / OS ────────────────────────────────────────────────────────────

variable "template_file_id" {
  description = "CT template to use, e.g. 'local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst'."
  type        = string
}

variable "os_type" {
  description = "OS type hint for Proxmox (unmanaged, ubuntu, debian, fedora, etc.)."
  type        = string
  default     = "ubuntu"
}

# ── Resources ────────────────────────────────────────────────────────────────

variable "cpu_cores" {
  description = "Number of CPU cores."
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM in megabytes."
  type        = number
  default     = 2048
}

variable "swap_mb" {
  description = "Swap in megabytes."
  type        = number
  default     = 1024
}

# ── Disk ─────────────────────────────────────────────────────────────────────

variable "disk_size" {
  description = "Root filesystem size in GB."
  type        = number
  default     = 20
}

variable "datastore_id" {
  description = "Proxmox storage ID for the root filesystem."
  type        = string
  default     = "local-lvm"
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "network_bridge" {
  description = "Linux bridge to attach the container's network interface to."
  type        = string
  default     = "vmbr0"
}

variable "network_ip" {
  description = "IPv4 address in CIDR notation, or 'dhcp'."
  type        = string
  default     = "dhcp"
}

variable "network_gateway" {
  description = "IPv4 default gateway. Leave empty when using DHCP."
  type        = string
  default     = ""
}

# ── Access ────────────────────────────────────────────────────────────────────

variable "root_password" {
  description = "Root password for the container."
  type        = string
  sensitive   = true
  default     = ""
}

variable "extra_username" {
  description = "Additional non-root user to create inside the container."
  type        = string
  default     = ""
}

variable "extra_user_password" {
  description = "Password for the extra non-root user."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_public_keys" {
  description = "SSH public keys to inject into root's authorized_keys."
  type        = string
  default     = ""
}

variable "start_on_create" {
  description = "Start the container immediately after creation."
  type        = bool
  default     = true
}

variable "start_on_boot" {
  description = "Start the container automatically when the Proxmox node boots."
  type        = bool
  default     = true
}

variable "unprivileged" {
  description = "Run as an unprivileged container (recommended)."
  type        = bool
  default     = true
}

variable "nesting" {
  description = "Enable nesting support (required for systemd 255+ inside the container)."
  type        = bool
  default     = true
}

# ── GitHub Runner ─────────────────────────────────────────────────────────────

variable "github_runner_targets" {
  description = "List of GitHub org or repo URLs the runner will register with. Use org URLs (https://github.com/org) to share across all repos in that org."
  type        = list(string)
}

variable "github_runner_tokens" {
  description = <<-EOT
    Comma-separated registration tokens, one per target URL in
    github_runner_targets order (each expires after 1 hour).

    Optional: the Ansible role only needs a token for a runner that is not yet
    registered, so an ordinary convergence run (config tweak, health-check
    update, drift repair) works with this empty. Tokens are only required when
    adding a target, raising github_runner_parallel, or rebuilding the host.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_runner_name" {
  description = "Display name for the runner shown in the GitHub UI."
  type        = string
  default     = "proxmox-lxc-runner"
}

variable "github_runner_labels" {
  description = "Extra labels to attach to the runner, e.g. [\"self-hosted\", \"linux\", \"proxmox\"]."
  type        = list(string)
  default     = ["self-hosted", "linux", "proxmox"]
}

variable "github_runner_user" {
  description = "OS user that runs the runner service."
  type        = string
  default     = "runner"
}

variable "github_runner_version" {
  description = "GitHub Actions runner binary version to download, e.g. 2.316.1."
  type        = string
  default     = "2.316.1"
}

variable "github_runner_parallel" {
  description = "Number of parallel runner instances to register per target (enables concurrent job execution)."
  type        = number
  default     = 2
}

# ── DNS ───────────────────────────────────────────────────────────────────────

variable "dns_servers" {
  description = <<-EOT
    DNS servers written into the container's /etc/resolv.conf by Proxmox.

    Pinning these here is deliberate: Proxmox rewrites the container's
    /etc/resolv.conf from the *node's* DNS configuration on every container
    start. On 2026-05-13 the node's DNS pointed at an unreachable WireGuard
    gateway (10.8.0.1) and every runner silently stopped picking up jobs for
    ~1.5 days while still reporting `active (running)`.
    See docs/incidents/2026-05-14-dns-outage.md.
  EOT
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]

  validation {
    condition     = length(var.dns_servers) > 0
    error_message = "At least one DNS server must be set; an empty list lets the Proxmox node's DNS win."
  }
}

variable "dns_domain" {
  description = "DNS search domain for the container. Empty leaves it unset."
  type        = string
  default     = ""
}

# ── Provisioning ──────────────────────────────────────────────────────────────

variable "github_pat" {
  description = <<-EOT
    Optional GitHub PAT (repo + workflow scope) stored on the container at
    /etc/github-runner/pat, mode 0600. When present the on-box health check can
    mint its own registration token and re-register a runner that GitHub has
    dropped, without anyone running `terraform apply`. Leave empty to disable
    self re-registration (the health check then only restarts services).
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "ansible_playbook" {
  description = "Path (relative to repo root) of the playbook that provisions the runners."
  type        = string
  default     = "ansible/playbooks/runners.yml"
}

variable "run_ansible" {
  description = "Run the Ansible provisioning playbook as part of `terraform apply`. Set false to manage infra only."
  type        = bool
  default     = true
}

variable "health_check_interval" {
  description = "How often the on-box runner health check runs (systemd OnUnitActiveSec syntax)."
  type        = string
  default     = "5min"
}

variable "cleanup_schedule" {
  description = "When the on-box disk cleanup runs (systemd OnCalendar syntax)."
  type        = string
  default     = "daily"
}

variable "work_dir_retention_days" {
  description = "Delete runner _work job directories untouched for this many days."
  type        = number
  default     = 7
}

variable "disk_warn_percent" {
  description = "Root filesystem usage percentage above which cleanup escalates to aggressive pruning."
  type        = number
  default     = 80
}

variable "runner_memory_max" {
  description = <<-EOT
    Optional per-runner systemd MemoryMax, e.g. "2G". When set, a runaway job
    is killed instead of the runner service that supervises it.

    Empty by default: capping memory only makes sense alongside a decision
    about CPU/RAM oversubscription (9 runners currently share 4 cores), which
    is a separate change.
  EOT
  type        = string
  default     = ""
}
