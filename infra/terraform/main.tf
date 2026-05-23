locals {
  talos_iso_boromir = "local:iso/talos-${var.talos_version}-amd64.iso"
  talos_iso_gandalf = "local:iso/talos-${var.talos_version}-amd64.iso"
}

# ── Control plane 0 — boromir (7700HQ) ────────────────────────────────────

resource "proxmox_virtual_environment_vm" "cp_0" {
  name      = "talos-cp-0"
  node_name = "boromir"
  tags      = ["talos", "control-plane"]

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_datastore
    size         = 50
    interface    = "virtio0"
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  cdrom {
    file_id   = local.talos_iso_boromir
    interface = "ide2"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["ide2", "virtio0"]

  initialization {
    ip_config {
      ipv4 {
        address = "10.0.20.21/24"
        gateway = var.gateway
      }
    }
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}

# ── Control plane 1 — boromir (7700HQ) ────────────────────────────────────

resource "proxmox_virtual_environment_vm" "cp_1" {
  name      = "talos-cp-1"
  node_name = "boromir"
  tags      = ["talos", "control-plane"]

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_datastore
    size         = 50
    interface    = "virtio0"
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  cdrom {
    file_id   = local.talos_iso_boromir
    interface = "ide2"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["ide2", "virtio0"]

  initialization {
    ip_config {
      ipv4 {
        address = "10.0.20.22/24"
        gateway = var.gateway
      }
    }
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}

# ── Worker 0 — boromir (7700HQ) — workload pesanti ────────────────────────

resource "proxmox_virtual_environment_vm" "worker_0" {
  name      = "talos-worker-0"
  node_name = "boromir"
  tags      = ["talos", "worker", "heavy"]

  cpu {
    cores = 4
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 6144
  }

  disk {
    datastore_id = var.storage_datastore
    size         = 100
    interface    = "virtio0"
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  cdrom {
    file_id   = local.talos_iso_boromir
    interface = "ide2"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["ide2", "virtio0"]

  initialization {
    ip_config {
      ipv4 {
        address = "10.0.20.23/24"
        gateway = var.gateway
      }
    }
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}

# ── Control plane 2 — gandalf (7500U) ─────────────────────────────────────

resource "proxmox_virtual_environment_vm" "cp_2" {
  name      = "talos-cp-2"
  node_name = "gandalf"
  tags      = ["talos", "control-plane"]

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_datastore
    size         = 50
    interface    = "virtio0"
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  cdrom {
    file_id   = local.talos_iso_gandalf
    interface = "ide2"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["ide2", "virtio0"]

  initialization {
    ip_config {
      ipv4 {
        address = "10.0.20.24/24"
        gateway = var.gateway
      }
    }
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}

# ── Worker 1 — gandalf (7500U) — workload leggeri ─────────────────────────

resource "proxmox_virtual_environment_vm" "worker_1" {
  name      = "talos-worker-1"
  node_name = "gandalf"
  tags      = ["talos", "worker", "light"]

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_datastore
    size         = 100
    interface    = "virtio0"
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  cdrom {
    file_id   = local.talos_iso_gandalf
    interface = "ide2"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["ide2", "virtio0"]

  initialization {
    ip_config {
      ipv4 {
        address = "10.0.20.25/24"
        gateway = var.gateway
      }
    }
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}
