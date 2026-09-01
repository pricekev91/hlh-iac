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

resource "proxmox_lxc" "hlh_freetoken" {
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

  # GPU passthrough for ROCm - 890M iGPU (gfx1150) ONLY
  # Do NOT use Proxmox native GPU passthrough here; it exposes all DRM devices
  # and causes ROCm to enumerate the RX 480 (gfx803, unsupported) as GPU 0.
  # Instead, deploy-hlh-freetoken.sh appends explicit cgroup2/device mount rules
  # that expose only the 890M's DRM nodes (card1, renderD129) + shared kfd.

  # Model storage volume mount (host /srv/ai/models -> LXC /srv/ai/models)
  mp0 {
    path    = var.model_mount_path
    storage = var.model_storage
  }
}

output "lxc_vmid" {
  value = proxmox_lxc.hlh_freetoken.vmid
}

output "lxc_hostname" {
  value = proxmox_lxc.hlh_freetoken.hostname
}

output "lxc_ip" {
  value = var.ip_cidr
}