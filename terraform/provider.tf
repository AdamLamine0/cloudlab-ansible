terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://192.168.64.172:8006/"
  api_token = var.proxmox_api_token
  insecure  = true
}
