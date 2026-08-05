# hlh-ai-engine

Infrastructure-as-Code for the HLH shared AI inference engine. Deploys a GPU-accelerated
llama.cpp runtime as a Proxmox LXC container with ROCm support.

## Executive Summary

This repository deploys and configures the **engine** LXC on the HLH Proxmox host. The
engine is a shared AI inference service consumed by all application repos (TrashPanda,
BrickCipher, VoxChimera).

- LXC 101, hostname `hlh-ai-engine`, IP `192.168.1.12`
- ROCm 7.14.0 with AMD RDNA 3 890M iGPU (gfx1150)
- llama.cpp backend serving native web UI on port 80
- Model storage on `RaidZ1-6TB` ZFS pool

## Repository Boundary

**Owns:**
- LXC lifecycle (create, configure, start) on Proxmox
- GPU passthrough configuration for ROCm
- Model storage mount wiring
- In-container ROCm and llama.cpp installation

**Does not own:**
- Proxmox host configuration (that is `iac-hlh`)
- Application logic or dashboard code (that is `TrashPanda`, `BrickCipher`, etc.)
- AI VM ROCm migration (planned as separate path in `iac-hlh`)

## Quick Start

Deploy the AI engine LXC on the Proxmox host:

```bash
./deploy-hlh-ai-engine.sh
```

Reconfigure an existing LXC via Ansible:

```bash
./configure-hlh-ai-engine.sh
```

Switch loaded models (inside LXC after deployment):

```bash
switch-model.sh
```

## Deployment Model

Deployment and configuration are separate phases:

1. **Provisioning**: `deploy-hlh-ai-engine.sh` creates the LXC, wires GPU passthrough,
   and pushes the in-container bootstrap script.
2. **Configuration**: `ansible/playbooks/hlh-ai-engine.yml` configures services,
   runtime, and networking inside the container.

## OpenTofu Module

For programmatic LXC creation via OpenTofu:

```hcl
module "hlh_ai_engine" {
  source = "./opentofu"
  pm_api_url         = var.pm_api_url
  pm_api_token_id    = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  target_node        = var.target_node
  hostname           = "hlh-ai-engine"
  vmid               = 101
  # ... other variables
}
```

## Runtime Contract

| Item | Value |
|------|-------|
| API endpoint | `http://192.168.1.12:80` |
| OpenAI-compatible base | `http://192.168.1.12:80/v1/` |
| Model storage | `/srv/ai/models` (host mount) |
| GPU device | `/dev/dri` + `/dev/kfd` bind-mount |
| Default model | Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf |

## Repository Layout

```
hlh-ai-engine/
├── deploy-hlh-ai-engine.sh          # LXC creation + GPU passthrough + bootstrap
├── configure-hlh-ai-engine.sh       # Ansible-based reconfiguration
├── ansible/
│   ├── inventories/hlh-ai-engine.yml
│   ├── playbooks/hlh-ai-engine.yml
│   └── files/configure-ai-engine-inside-lxc.sh
├── opentofu/
│   ├── main.tf
│   └── variables.tf
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
├── CHANGELOG.md
└── README.md
```

## GPU Backend Notes

**ROCm (HIP) only.** Vulkan was evaluated but disabled due to missing
SPIRV-Headers in the ROCm 7.x stack on Ubuntu 24.04. All inference runs
on AMD GPU compute via HIP/ROCm.

- ROCm 7.14.0 supports gfx1150 (Radeon 890M / Strix Halo) natively via rocBLAS
- `HSA_OVERRIDE_GFX_VERSION=11.5.0` is set in the systemd unit to ensure compatibility
- AMDGPU_TARGETS=gfx1150 at build time

## llama.cpp Tuning Reference

Default llama-server flags (from systemd unit):

| Flag | Default | Description |
|------|---------|-------------|
| `--model` | mounted GGUF path | Model file |
| `--host` | `0.0.0.0` | Listen on all interfaces |
| `--port` | `80` | Native web UI + API port |
| `--ctx-size` | `4096` | Context window (switch via `switch-model.sh`) |
| `-ngl` | `48` | GPU offload layers |
| `--batch-size` | `128` | Batch size for inference |
| `--parallel` | `1` | Request parallelism |
| `--cache-type-k` | `q4_0` | KV key cache quantization |
| `--cache-type-v` | `q4_0` | KV value cache quantization |
| `--spec-type` | `draft-mtp` | MTP speculative decoding (auto-detected for MTP models) |
| `--spec-draft-n-max` | `3` | MTP draft tokens |

Context size options (via `switch-model.sh`):

| Option | ctx-size | Description |
|--------|----------|-------------|
| 1 | 98304 (96K) | Maximum long-context |
| 2 | 73728 (72K) | Extended long-context |
| 3 | 65536 (64K) | Full long-context |
| 4 | 32768 (32K) | Half, saves ~50% KV VRAM |
| 5 | 16384 (16K) | Quarter, minimal KV usage |
| 6 | 8192 (8K) | Minimal, maximum VRAM headroom |

KV cache VRAM estimates:

| Context | q4_0 | q6_0 | q8_0 |
|---------|------|------|------|
| 96K | ~12 GB | ~18 GB | ~24 GB |
| 72K | ~9 GB | ~14 GB | ~18 GB |
| 64K | ~8 GB | ~12 GB | ~18 GB |
| 32K | ~4 GB | ~6 GB | ~9 GB |
| 16K | ~2 GB | ~3 GB | ~5 GB |
| 8K | ~1 GB | ~2 GB | ~3 GB |

## Health Checks & Service Lifecycle

| Check | Command |
|-------|---------|
| Service status | `systemctl status ai-engine` |
| Live health | `curl -s http://localhost:80/health` |
| Model info | `curl -s http://localhost:80/v1/models` |
| GPU usage | `rocm-smi` |
| Logs | `journalctl -u ai-engine -f` |

The `switch-model.sh` script waits up to 30 seconds for the service to come
back up after a model switch, confirming `systemctl is-active --quiet ai-engine`.

## Governance

This repo is a submodule of `iac-hlh`. Deployments consume pinned commits for
deterministic results. See the HLH Agile Design Handbook for the full architecture
and dependency map.
