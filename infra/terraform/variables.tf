variable "proxmox_endpoint" {
  description = "URL API del cluster Proxmox (punta a qualsiasi nodo)"
  type        = string
  default     = "https://10.0.20.11:8006"
}

variable "proxmox_token" {
  description = "API token Proxmox — valido per tutto il cluster"
  type        = string
  sensitive   = true
}

variable "talos_version" {
  type    = string
  default = "v1.7.6"
}

variable "storage_datastore" {
  description = "Datastore Proxmox per i dischi VM"
  type        = string
  default     = "local-lvm"
}

variable "gateway" {
  type    = string
  default = "10.0.20.1"
}
