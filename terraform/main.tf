# Two-VM compute layer, cloned from template 9000.
# k3s-node   -> 192.168.1.80  (gets kube_node_cloudinit via Ansible)
# nomad-node -> 192.168.1.81  (gets nomad_node_cloudinit via Ansible)
# Test IPs (.80/.81), deliberately NOT the real .50/.51 — see handoff §22.

locals {
  vms = {
    "k3s-node" = {
      vm_id = 110
      ip    = "192.168.1.80"
    }
    "nomad-node" = {
      vm_id = 111
      ip    = "192.168.1.81"
    }
  }
}

resource "proxmox_virtual_environment_vm" "cloudlab_vm" {
  for_each = local.vms

  name      = each.key
  node_name = "pve"
  vm_id     = each.value.vm_id

  clone {
    vm_id = 9000
    full  = true
  }

  lifecycle {
    ignore_changes = [clone]
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
    memory = 16
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 20
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
  }

  network_device {
    bridge = "vmbr1"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "192.168.1.1"
      }
    }

    user_account {
      username = "root"
      password = "azerty12"
      keys     = []
    }
  }
}
