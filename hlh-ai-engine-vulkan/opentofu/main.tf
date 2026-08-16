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

resource "proxmox_lxc" "hlh_ai_engine_vulkan" {
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

  # GPU passthrough - AMD GPU for Vulkan (RADV via Mesa)
  device {
    name = "gpu0"
    gpu  = "gfx1150"
  }

  # Model storage volume mount (host /srv/ai/models -> LXC /srv/ai/models)
  mp0 {
    path    = var.model_mount_path
    storage = var.model_storage
  }

  # NOTE: the cgroup2 device allow rule (c 226:* rwm) and
  # bind-mount entry (/dev/dri) must be appended to the
  # LXC .conf file after creation. Use deploy-hlh-ai-engine-vulkan.sh for
  # full provisioning or run manually:
  #   pct set <VMID> --lxc.conf 'lxc.cgroup2.devices.allow: c 226:* rwm'
  #   pct set <VMID> --lxc.conf 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir'
}

output "lxc_vmid" {
  value = proxmox_lxc.hlh_ai_engine_vulkan.vmid
}

output "lxc_hostname" {
  value = proxmox_lxc.hlh_ai_engine_vulkan.hostname
}
