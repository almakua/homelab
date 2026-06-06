locals {
  templates = {
    "boromir" = 9999
    "gandalf" = 9000
  }

  vms = {
    "k3s-cp-0"     = { node = "boromir", ip = "10.0.20.21", cores = 2, memory = 4096, disk = 40 }
    "k3s-cp-1"     = { node = "boromir", ip = "10.0.20.22", cores = 2, memory = 4096, disk = 40 }
    "k3s-cp-2"     = { node = "gandalf", ip = "10.0.20.24", cores = 2, memory = 4096, disk = 40 }
    "k3s-worker-0" = { node = "boromir", ip = "10.0.20.23", cores = 4, memory = 6144, disk = 60 }
    "k3s-worker-1" = { node = "gandalf", ip = "10.0.20.25", cores = 2, memory = 4096, disk = 60 }
  }
}

resource "proxmox_virtual_environment_vm" "k3s_node" {
  for_each = local.vms

  name      = each.key
  node_name = each.value.node
  tags      = ["k3s", "ubuntu"]

  clone {
    vm_id = local.templates[each.value.node]
    full  = true
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  initialization {
    user_account {
      username = var.vm_user
      keys     = [var.ssh_public_key]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "10.0.20.1"
      }
    }

    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }
  }
}
