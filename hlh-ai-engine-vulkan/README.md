# hlh-ai-engine-vulkan

Infrastructure-as-Code for the HLH shared AI inference engine (Vulkan variant).
Deploys a GPU-accelerated llama.cpp runtime as a Proxmox LXC container using the
Vulkan backend (Mesa RADV) instead of ROCm/HIP.

## Executive Summary

This repository deploys and configures the **engine-vulkan** LXC on the HLH Proxmox
host. It is a sibling of `hlh-ai-engine` (ROCm backend) running the same shared AI
inference workload.

- LXC 120, hostname `hlh-ai-engine-vulkan`, IP `192.168.1.20`
- Vulkan backend via Mesa RADV on AMD RDNA 3 890M iGPU (gfx1150)
- llama.cpp backend serving native web UI on port 80
- Model storage shared with `hlh-ai-engine` on `RaidZ1-6TB` ZFS pool (`/srv/ai/models`)

## Repository Boundary

**Owns:**
- LXC lifecycle (create, configure, start) on Proxmox
- GPU passthrough configuration for Vulkan (`/dev/dri` only — no `/dev/kfd`)
- Model storage mount wiring
- In-container Mesa Vulkan and llama.cpp installation

**Does not own:**
- Proxmox host configuration (that is `iac-hlh`)
- Application logic or dashboard code (that is `TrashPanda`, `BrickCipher`, etc.)

## Quick Start

Deploy the Vulkan AI engine LXC on the Proxmox host:

```bash
./deploy-hlh-ai-engine-vulkan.sh
```

Reconfigure an existing LXC via Ansible:

```bash
./configure-hlh-ai-engine-vulkan.sh
```

Switch loaded models (inside LXC after deployment):

```bash
switch-model.sh
```

> Note: `hlh-ai-engine` and `hlh-ai-engine-vulkan` share the same iGPU. Do not run
> both inference engines simultaneously if GPU memory is a constraint.

## Deployment Model

Deployment and configuration are separate phases:

1. **Provisioning**: `deploy-hlh-ai-engine-vulkan.sh` creates the LXC, wires GPU
   passthrough (`/dev/dri`), and pushes the in-container bootstrap script.
2. **Configuration**: `ansible/playbooks/hlh-ai-engine-vulkan.yml` configures
   services, runtime, and networking inside the container.

## OpenTofu Module

For programmatic LXC creation via OpenTofu:

```hcl
module "hlh_ai_engine_vulkan" {
  source = "./opentofu"
  pm_api_url         = var.pm_api_url
  pm_api_token_id    = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  target_node        = var.target_node
  hostname           = "hlh-ai-engine-vulkan"
  vmid               = 120
  # ... other variables
}
```

## Runtime Contract

| Item | Value |
|------|-------|
| API endpoint | `http://192.168.1.20:80` |
| OpenAI-compatible base | `http://192.168.1.20:80/v1/` |
| Model storage | `/srv/ai/models` (host mount, shared with hlh-ai-engine) |
| GPU device | `/dev/dri` bind-mount only (no `/dev/kfd`) |
| Default model | Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf |

## Repository Layout

```
hlh-ai-engine-vulkan/
├── deploy-hlh-ai-engine-vulkan.sh    # LXC creation + GPU passthrough + bootstrap
├── configure-hlh-ai-engine-vulkan.sh # Ansible-based reconfiguration
├── ansible/
│   ├── inventories/hlh-ai-engine-vulkan.yml
│   ├── playbooks/hlh-ai-engine-vulkan.yml
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

**Vulkan only.** This variant drops ROCm/HIP entirely:

- llama.cpp built with `GGML_VULKAN=ON`, `GGML_HIP=OFF`, `GGML_CUDA=OFF`
- Mesa Vulkan stack: `libvulkan1`, `libvulkan-dev`, `mesa-vulkan-drivers` (RADV),
  `vulkan-tools`, `glslc`
- RADV supports gfx1150 (Radeon 890M / Strix Halo) natively — no
  `HSA_OVERRIDE_GFX_VERSION` needed
- GPU passthrough is `/dev/dri` only; `/dev/kfd` is ROCm-specific and not required

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
| GPU usage | `amdgpu_top` (or `vulkaninfo --summary`) |
| Logs | `journalctl -u ai-engine -f` |

The `switch-model.sh` script waits up to 30 seconds for the service to come
back up after a model switch, confirming `systemctl is-active --quiet ai-engine`.

## Governance

This repo is a submodule of `iac-hlh`. Deployments consume pinned commits for
deterministic results. See the HLH Agile Design Handbook for the full architecture
and dependency map.