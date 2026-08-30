terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = ">= 2.7.2"
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true
}

resource "proxmox_lxc" "hlh_ai_engine_egpu_vulkan" {
  target_node  = var.target_node
  hostname     = var.hostname
  ostemplate   = var.ostemplate
  vmid         = var.vmid
  cores        = var.cores
  memory       = var.memory
  swap         = var.swap
  unprivileged = false
  start        = true
  description  = var.description

  features {
    nesting = true
    keyctl  = true
    fuse    = true
  }

  network {
    name   = "eth0"
    bridge = var.bridge
    ip     = var.ip_cidr
    gw     = var.gateway
    tag    = var.network_tag
  }

  password = var.lxc_root_password != "" ? var.lxc_root_password : null

  rootfs {
    storage = var.storage
    size    = "${var.rootfs_size_gb}G"
  }

  # Native PCI passthrough - eGPU via OCuLink (card-agnostic)
  # Passes through the entire IOMMU group containing the OCuLink-connected GPU.
  # The PCI address is the physical OCuLink connector address — stable across
  # card swaps (RX480 -> NVIDIA K80 -> AMD MI60, etc.).
  # The iGPU (890M on bus c6) is NOT in this IOMMU group, so it's isolated.
  # NOTE: if the IOMMU group has multiple devices (GPU + audio companion), add
  # additional device blocks with incrementing hostpciN names.
  device {
    name = "hostpci0"
    id   = var.egpu_pci_address
  }

  # Model storage volume mount (host /srv/ai/models -> LXC /srv/ai/models)
  mp0 {
    path    = var.model_mount_path
    storage = var.model_storage
  }

  # NOTE: the cgroup2 device allow rule (c 226:* rwm) and
  # bind-mount entry (/dev/dri) must be appended to the
  # LXC .conf file after creation. Use deploy-hlh-ai-engine-egpu-vulkan.sh for
  # full provisioning or run manually:
  #   pct set <VMID> --lxc.conf 'lxc.cgroup2.devices.allow: c 226:* rwm'
  #   pct set <VMID> --lxc.conf 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir'
}

output "lxc_vmid" {
  value = proxmox_lxc.hlh_ai_engine_egpu_vulkan.vmid
}

output "lxc_hostname" {
  value = proxmox_lxc.hlh_ai_engine_egpu_vulkan.hostname
}
