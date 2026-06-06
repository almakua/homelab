variable "proxmox_endpoint" {
  description = "URL API del cluster Proxmox"
  type        = string
  default     = "https://10.0.20.11:8006"
}

variable "proxmox_token" {
  description = "API token Proxmox"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Chiave SSH pubblica per accedere alle VM"
  type        = string
}

variable "vm_user" {
  description = "Utente di default sulle VM"
  type        = string
  default     = "ubuntu"
}

