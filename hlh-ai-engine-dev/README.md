# hlh-ai-engine-dev

Greenfield Proxmox LXC deployment for a ROCm + vLLM development engine on prox01.

## Fixed deployment defaults

- CTID: 110
- Hostname: hlh-ai-engine-dev.mizertech.net
- IP: 192.168.1.16/24
- Gateway: 192.168.1.1
- DNS: 192.168.1.1, 192.168.1.2
- vCPU: 12
- RAM: 55296 MB (54 GB)
- Disk: 64 GB
- Base image: Ubuntu 26.04 template
- LXC privilege mode: unprivileged by default

## Why unprivileged by default

Unprivileged LXC is the safer baseline and should work for ROCm userspace if /dev/dri and /dev/kfd are correctly passed through.
If GPU permissions are blocked by host-side UID/GID mapping constraints, switch to privileged as an operational fallback.

## Quick start

1. Ensure prox01 has:
   - Ubuntu 26.04 LXC template present.
   - AMD iGPU stack working on host.
   - /dev/dri and /dev/kfd present on host.
2. Run deploy from this directory:

   PROXMOX_SSH=root@prox01 ./deploy-hlh-ai-engine-dev.sh

3. Verify:

   ssh root@prox01 "pct exec 110 -- verify-rocm-vllm"

## Optional overrides

You can override all defaults at runtime, for example:

CTID=110 TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst STORAGE=local-lvm PROXMOX_SSH=root@prox01 ./deploy-hlh-ai-engine-dev.sh

## Key files

- deploy-hlh-ai-engine-dev.sh: end-to-end orchestration from workstation to prox01 and CT bootstrap.
- scripts/prox01-create-lxc-110.sh: creates or reconciles CT config and GPU passthrough settings on prox01.
- scripts/in-ct-install-rocm-vllm.sh: installs ROCm userspace, amd-smi/rocm-smi tools, vLLM, and verification helpers.
- docs/OPERATIONS.md: troubleshooting and privilege fallback runbook.
