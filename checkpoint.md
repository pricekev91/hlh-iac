# HLH-IAC Checkpoint — 2026-09-09 14:00 UTC — CUDA K80 Working Fallback

> Single-file bootstrap to resume from scratch. Hosts, auth, IAC, drivers, architecture, and current/next steps. This is the CUDA fallback point before Vulkan test.

---

## 1. Hosts & Access

| Host | IP | Role | OS / Kernel | Access | Note |
|------|----|------|-------------|--------|------|
| **prox01** | `192.168.1.10` | Proxmox 9.2 host | `Debian 13 trixie` / `7.0.14-11-pve` (also `6.5.13-5`, `6.17.13-21` installed) | `root@192.168.1.10` `keybased` `~/.ssh/id_ed25519` (Ed25519 `AAAAC3NzaC1lZDI1NTE5AAAAIDS0C6mISIuMV0KkpbC6ulaHjDyhqQoP1R8YoEpHI862` `prox01` + `~/.ssh/id_rsa`) | `pve-manager/9.2.10` `systemd-boot` ESP `2086-071E` `/dev/nvme0n1p2` `ZFS rpool` + `RaidZ1-6TB` |
| **hlh-ai-engine** | `192.168.1.12` | LXC 101 `hlh-ai-engine` ROCm 890M | `Ubuntu 24.04` `5.15+` inside | `root@192.168.1.12` `keybased` same key | `490M` `Strix Halo 890M` `1002:150e` `512M VRAM` `gfx1150` |
| **hlh-ai-engine-egpu-k80** | `192.168.1.31` | LXC 131 `hlh-ai-engine-egpu-k80` CUDA K80 | `Ubuntu 24.04` | `root@192.168.1.31` `keybased` via `pct exec 131` from `prox01` | `Tesla K80` dual `GK210GL` `10de:102d` `cc 3.7` `2×11441MiB` via OCuLink `c5:00.0` `c7:00.0` + `c8:00.0` `IOMMU 23/24` |
| (siblings) | `192.168.1.20` | LXC 120 `hlh-ai-engine-vulkan` | Vulkan 890M iGPU | — | stopped |
| | `192.168.1.30` | LXC 130 `hlh-ai-engine-egpu-vulkan` | Vulkan eGPU RX480 `gfx803` | — | stopped — shares single OCuLink slot with 131, cannot run together |
| | `192.168.1.13` | LXC 102 `hlh-docker` | Docker | — | running |
| | `192.168.1.40` | LXC 140 `hlh-ai-engine-freetoken` | ROCm | — | stopped |
| Gateway | `192.168.1.1` | `vmbr0` `r8169 c4:00.0` | — | — | `ig` |

**Auth:** All `root` via `~/.ssh/id_ed25519` (no password). `Proxmox` API `telmate/proxmox` `pm_api_url` `https://192.168.1.10:8006/` `pm_api_token_id/secret` in `opentofu/variables.tf`. `pct exec <vmid>` from `prox01` for LXC shell.

**Repo:** `pricekev91/hlh-iac` `main` `git@github.com:pricekev91/hlh-iac.git` cloned at `/home/pricekev/git/hlh-iac` (laptop) and `/root/git/hlh-iac` (prox01). Push via `ssh` `git@github.com`, pull via `https` or `ssh`.

**Model storage:** Host `RaidZ1-6TB` ZFS `RaidZ1-6TB/ai/models` `/srv/ai/models` `775` `zfs` `xattr,noacl` bind-mounted as `mp0` into every `LXC` at `/srv/ai/models`.

---

## 2. Text Architecture Diagram

```
[ Laptop hlh-iac ] --git push--> [ GitHub pricekev91/hlh-iac main ] <--git pull-- [ prox01 192.168.1.10 Proxmox 9.2 ]
                                                      | 7.0.14-11-pve Debian trixie 24c 64GB ZFS rpool/RaidZ1-6TB
                                                      | vmbr0 192.168.1.1
                                                      | ESP 2086-071E systemd-boot pin 7.0.14-11-pve
                                                      |
                                      +---------------+---------------+---------------+
                                      |               |               |               |
                                   LXC 101          LXC 131         LXC 130         LXC 120 ...
                                192.168.1.12     192.168.1.31      192.168.1.30    192.168.1.20
                              hlh-ai-engine   hlh-ai-engine-   hlh-ai-engine-   hlh-ai-engine-
                                               egpu-k80         egpu-vulkan      vulkan
                              ROCm 7.14        CUDA 11.8        Vulkan           Vulkan
                              890M gfx1150    K80 GK210 x2     RX480 gfx803     890M iGPU
                              512M VRAM       2x11441MiB       8GB              512M
                              /dev/kfd +      /dev/nvidia0/1   /dev/dri         /dev/dri
                              /dev/dri        nvidiactl/uvm    c226:* rwm       c226:* rwm
                              card0/renderD128 195:* 507:*510:*  /dev/dri bind    /dev/dri bind
                              |               |               |
                              +-------+-------+               |
                                      | OCuLink c5:00.0 (single slot, only one of 130/131 can run)
                                      |
                                   [ eGPU Dock ]  Tesla K80 (c7:00.0 + c8:00.0) 10de:102d rev a1
                                                  or RX480 (when swapped)

All LXCs: privileged (unprivileged 0), nesting=1,keyctl=1,fuse=1, onboot 1 (101 onboot 1, 131 onboot 1 but must stop 130 first),
          rootfs RaidZ1-6TB 64G, 12c 8G (101 49G), mp0 /srv/ai/models
```

---

## 3. IAC Layout (what owns what)

```
hlh-iac/
  hlh-ai-engine/                 # LXC 101 192.168.1.12 ROCm 890M (Strix Halo)
    deploy-hlh-ai-engine.sh
    opentofu/main.tf
    ansible/files/configure-ai-engine-inside-lxc.sh  # ROCm 7.14 gfx1150 + switch-model.sh v1.7.0
  hlh-ai-engine-egpu-vulkan/     # LXC 130 192.168.1.30 Vulkan RX480
    deploy-hlh-ai-engine-egpu-vulkan.sh
  hlh-ai-engine-egpu-k80/        # LXC 131 192.168.1.31 CUDA K80  <-- DUAL K80
    deploy-hlh-ai-engine-egpu-k80.sh     # pinned CUDA 11.8.0-1 + driver 470.256.02 cc37 + nvidia-uvm persistence
    opentofu/main.tf
    ansible/files/configure-ai-engine-inside-lxc.sh # CUDA 11.8 + k80-switch-model.sh v1.7.0-k80 -> /usr/local/bin/k80-switch-model.sh + /srv/ai/models/k80-switch-model.sh
    ansible/files/k80-switch-model.sh    # standalone copy 289 lines v1.7.0-k80
```

---

## 4. Pinned Versions (K80 CUDA path)

| Component | Version | Why | Where Pinned |
|-----------|---------|-----|--------------|
| Host kernel | `7.0.14-11-pve` pinned | 890M needs ≥6.11 DCN 3.5 | proxmox-boot-tool kernel pin |
| NVIDIA driver | `470.256.02` last Kepler cc3.7 | K80 GK210 EOL | deploy: NVIDIA_TESLA_470_VERSION + joanbm patch |
| CUDA | `11.8.0-1` `11.8.89` | last with cc3.7 | ubuntu2204 repo |
| LXC gcc | `gcc-11` | CUDA 11.8 rejects gcc>11 | configure |
| LXC nvidia userspace | `470.256.02-0ubuntu0.24.04.1` | avoid 535 transitional | configure |
| llama.cpp | `0.4.0-dev 304665f GGML_CUDA=ON ARCH37` | K80 | configure |
| nvidia_uvm | `507:0` + `nvidia-uvm-devices.service` | fix reboot CPU fallback | deploy + /etc/modules-load.d/nvidia.conf + /etc/systemd/system/nvidia-uvm-devices.service |

---

## 5. Current State (as of 2026-09-09 14:00 UTC) — CUDA Fallback Point

**Host prox01:**
* `7.0.14-11-pve` pinned, `nvidia-smi 470.256.02 2x K80 11441MiB P0 55W/73W`, `nvidia_uvm 1368064`, `507:0` via `nvidia-uvm-devices.service` Before pve-guests
* `pct list` 101 running, 102 running, 131 running, 130/120 stopped

**LXC 131 hlh-ai-engine-egpu-k80 192.168.1.31:**
* `ai-engine.service` active `Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf` `32768 ctx` `-ngl 99` `batch 512` `q4_0` `CUDA_VISIBLE_DEVICES=0,1` `PID 21262` after switch tests
* `nvidia-smi` `470.256.02` `2 GPUs` `3324/3125MiB` (Mellum) or `11022/11177MiB` (Qwen35B MTP 8192), `llama-bench pp20 42.6 tg128 17.9 CUDA`
* `k80-switch-model.sh v1.7.0-k80` at `/usr/local/bin/k80-switch-model.sh` + `/srv/ai/models/k80-switch-model.sh` (single source) — banner VRAM 2x12GB=24GB, MTP/ngram/none, /health probe
* **Known failure:** `Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf` with `--spec-type draft-mtp --spec-draft-n-max 5` ABRT `CUBLAS_STATUS_ARCH_MISMATCH` on `cublasGemmEx` `device 1` `ggml-cuda.cu:1551` — MTP draft kernels unsupported on cc3.7. Without MTP `3 tok/s` on Qwen3.8 27B, with MTP cannot run on CUDA. `failed to fit params` warning for -ngl 99 is benign (forced).
* `Qwen3.8-27B` (frontier, small footprint) target: want MTP speed, currently CUDA without MTP is unusable.

**IAC git:** `pricekev91/hlh-iac main` at `d774a43` `fix: remove extra symlinks, keep only k80-switch-model.sh` (ahead). Tag `k80-dual-gpu-working` on `6b2b849` marks dual GPU working.

---

## 6. Next Step: Test Vulkan for K80

* Build `llama.cpp` with `GGML_VULKAN=ON GGML_CUDA=OFF` on 131, test `Qwen3.8-27B` with `vulkan + MTP` vs `cuda + none`. Fallback to this CUDA checkpoint if Vulkan not faster (llvmpipe risk per checkpoint 03:30).
* MI60 (gfx900) arriving in week — shared `/srv/ai/models/k80-switch-model.sh` designed for reuse.

---

## 7. Quick Resume Commands

```bash
ssh root@192.168.1.10 "uname -r; nvidia-smi; dkms status"
ssh root@192.168.1.10 "pct list; pct status 131; pct exec 131 -- nvidia-smi -L; pct exec 131 -- systemctl status ai-engine --no-pager"
pct exec 131 -- k80-switch-model.sh  # on 131 via pct exec 131 -- bash
ssh root@192.168.1.10 "pct exec 131 -- bash -c 'curl -s http://127.0.0.1:80/health'"
# deploy after IAC change
cd /root/git/hlh-iac && git pull && bash hlh-ai-engine-egpu-k80/deploy-hlh-ai-engine-egpu-k80.sh --skip-host-driver
# fallback to CUDA checkpoint
git checkout k80-dual-gpu-working  # or d774a43
```

