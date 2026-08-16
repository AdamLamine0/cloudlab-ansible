variable "proxmox_api_token" {
  description = "Proxmox API token in the form root@pam!terraform=<secret>"
  type        = string
  sensitive   = true
}
