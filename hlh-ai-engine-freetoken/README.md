# hlh-ai-engine-freetoken

Infrastructure-as-Code for deploying FreeToken AI inference engine on HLH Proxmox host.

## Executive Summary

This repository deploys and configures the **FreeToken** LXC on the HLH Proxmox host.
FreeToken is FlashML's MoE-optimized serving engine (~2x faster than llama.cpp), running
on AMD ROCm with the Radeon 890M iGPU.

- LXC 140, hostname `hlh-ai-engine-freetoken`, IP `192.168.1.40`
- ROCm 7.14.0 with AMD RDNA 3 890M iGPU (gfx1150)
- FreeToken serving on port 1919 (OpenAI + Anthropic API)
- Open WebUI on port 80 (Qwen-Chat style UI)
- Built-in authentication for Open WebUI
- Model storage on `RaidZ1-6TB` ZFS pool

## Repository Boundary

**Owns:**
- LXC 140 lifecycle (create, configure, start) on Proxmox
- GPU passthrough configuration for ROCm (same 890M setup as LXC 101)
- Model storage mount wiring
- In-container FreeToken installation via `uv`

**Does not own:**
- Proxmox host configuration (`iac-hlh`)
- Application logic or dashboard code
- llama.cpp engine (that is `hlh-ai-engine`)

## Quick Start

Deploy the FreeToken LXC on the Proxmox host:

```bash
./deploy-hlh-ai-engine-freetoken.sh
```

Reconfigure an existing LXC via Ansible:

```bash
./configure-hlh-ai-engine-freetoken.sh
```

## Deployment Model

Deployment and configuration are separate phases:

1. **Provisioning**: `deploy-hlh-ai-engine-freetoken.sh` nukes & recreates the LXC,
   wires GPU passthrough, and pushes the in-container bootstrap script.
2. **Configuration**: `ansible/playbooks/hlh-ai-engine-freetoken.yml` configures
   FreeToken, systemd service, and networking inside the container.

## OpenTofu Module

For programmatic LXC creation via OpenTofu:

```hcl
module "hlh_ai_engine_freetoken" {
  source = "./opentofu"
  pm_api_url         = var.pm_api_url
  pm_api_token_id    = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  target_node        = var.target_node
  hostname           = "hlh-ai-engine-freetoken"
  vmid               = 140
  # ... other variables
}
```

## Runtime Contract

| Item | Value |
|------|-------|
| Web UI (Open WebUI) | `http://192.168.1.40:80` |
| API endpoint (OpenAI) | `http://192.168.1.40:1919/v1/` |
| API endpoint (Anthropic) | `http://192.168.1.40:1919/v1/messages` |
| Model storage | `/srv/ai/models` (host mount) |
| GPU device | `/dev/dri` + `/dev/kfd` bind-mount (890M iGPU) |
| Default model | Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf (MoE) |
| Serving port | 1919 |

## Repository Layout

```
hlh-ai-engine-freetoken/
├── deploy-hlh-ai-engine-freetoken.sh    # LXC nuke & redeploy + bootstrap
├── configure-hlh-ai-engine-freetoken.sh # Ansible-based reconfiguration
├── ansible/
│   ├── inventories/hlh-ai-engine-freetoken.yml
│   ├── playbooks/hlh-ai-engine-freetoken.yml
│   └── files/configure-freetoken-inside-lxc.sh
├── opentofu/
│   ├── main.tf
│   └── variables.tf
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
├── CHANGELOG.md
└── README.md
```

## GPU Backend

**ROCm (AMD) via the 890M iGPU.** Same GPU passthrough setup as `hlh-ai-engine` (LXC 101):
- Only `card1` (226:1) and `renderD129` (226:129) exposed to avoid ROCm seeing the RX 480
- Shared `/dev/kfd` for ROCm device access
- `HSA_OVERRIDE_GFX_VERSION=11.5.0` in systemd unit

## Health Checks & Service Lifecycle

| Check | Command |
|-------|---------|
| Service status | `systemctl status freetoken` |
| Live health | `curl -s http://localhost:1919/health` |
| OpenAI models | `curl -s http://localhost:1919/v1/models` |
| GPU usage | `rocm-smi` |
| Logs | `journalctl -u freetoken -f` |

## Governance

This repo is a submodule of `iac-hlh`. Deployments consume pinned commits for deterministic results.
