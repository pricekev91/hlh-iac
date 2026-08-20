# DONE

This is what is already implemented and verified in this repository.

## LXC Deployment

- Direct Proxmox LXC creation via `deploy-hlh-ai-engine.sh` (no OpenTofu required for initial setup)
- Privileged LXC 101 with hostname `hlh-ai-engine`
- 48 GiB RAM, 12 cores, 64 GiB rootfs on `RaidZ1-6TB` pool
- Static IP assignment: `192.168.1.12/24`
- Nesting and keyctl features enabled
- Prompt-before-redeploy guard prevents accidental LXC recreation

## GPU Passthrough

- AMD iGPU `/dev/dri` bind-mount for ROCm device access
- AMD iGPU `/dev/kfd` bind-mount for HIP/ROCm compute
- cgroup2 device allow rules: `c 226:* rwm`, `c 511:0 rwm`
- GPU detected as gfx1150 (Radeon 890M, RDNA 3)
- `HSA_OVERRIDE_GFX_VERSION=11.5.0` set in systemd unit

## ROCm / Runtime

- ROCm 7.14.0 installed (repo-based, not bundled .deb)
- ROCm 7.14.0 pin via `amdrocm7.14-gfx1150` + `amdrocm-core-dev7.14-gfx1150` packages
- ROCm 7.14.0 repo keyrings and APT pinning configured
- llama.cpp built from HEAD with HIP/ROCm only (Vulkan disabled)
- llama-server native web UI on port 80 (no nginx)
- Model download skipped when `/srv/ai/models` mount already contains GGUF files
- MTP (Mixture of Parameter Transfer) auto-detect in switch-model.sh

## Model Management

- switch-model.sh v1.4.2 with MTP auto-detect, ctx-size 96K support
- Model storage: host `/srv/ai/models` bind-mounted to LXC `/srv/ai/models`
- Default model pinned to `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`
- Preferred models list: Qwen3-Coder-30B, Qwen3.6-35B-A3B, Qwen3-Coder-Next
- MTP models detected by filename (case-insensitive 'MTP' match)
- Atomic ExecStart rewrite via awk (no sed fragility)
- Startup wait loop + web UI URL confirmation after model switch

## Networking

- llama-server native web UI + API on port 80 inside LXC
- OpenAI-compatible API at port 80/v1/

## Ansible Configuration

- Ansible inventory: `ansible/inventories/hlh-ai-engine.yml`
- Playbook: `ansible/playbooks/hlh-ai-engine.yml`
- Bootstrap script: `ansible/files/configure-ai-engine-inside-lxc.sh` (v0.9.0)
- SSH key-based auth: `~/.ssh/id_ed25519`
- Reconfiguration via `configure-hlh-ai-engine.sh` with `--host` and `--offline` flags

## Speculative Decoding (DFlash2 / MTP)

- llama.cpp pinned to `5ecbe1a` (PR #27342) for DFlash2 draft-model support
- `switch-model.sh` v1.6.1: DFlash2 option auto-pairs same-family draft GGUF
  (`Qwen3.8-27B-DFlash2-Q4_K_M.gguf`, from `z-lab/Qwen3.8-27B-DFlash2-GGUF`),
  readiness check probes `/health` (crash-loop detection)
- DFlash2 draft verified working: acceptance 0.35-0.92, mean run 3.5-7.0
- Known limitation: Qwen3.8-27B caps at ~4.3 tok/s on this iGPU (Gated Delta Net
  fused kernels unsupported on HIP); Qwen3.6-27B+MTP is the fast config (~7.6-7.8)

## OpenTofu Provisioning

- Proxmox provider: `telmate/proxmox >= 2.7.2`
- LXC resource with GPU passthrough, network, and storage configuration
- Variables for API URL, token auth, network, and storage
- GPU passthrough (cgroup allow + mount entries) included in tofu module

## Configuration Scripts

- `deploy-hlh-ai-engine.sh` - Full LXC creation, GPU passthrough, bootstrap
- `configure-hlh-ai-engine.sh` - Ansible-based reconfiguration with host/offline flags

## Service Lifecycle

- Systemd auto-restart on failure (`Restart=on-failure`, `RestartSec=10`)
- `switch-model.sh` waits up to 30 seconds for service to come back up
- `rocm-smi` and `llama-server --version` verification in bootstrap
