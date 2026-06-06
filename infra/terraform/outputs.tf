output "vm_ips" {
  value = { for name, vm in proxmox_virtual_environment_vm.k3s_node : name => vm.ipv4_addresses }
}

