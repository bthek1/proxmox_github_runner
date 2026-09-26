# versions.tf — Terraform and provider version constraints

terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.75"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
