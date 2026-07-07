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
- LXC privilege mode: privileged by default

## Why privileged by default

ROCm on AMD iGPU in LXC is substantially more reliable in privileged mode because `/dev/kfd` and DRM access can be blocked by unprivileged mapping and host policy.
You can still test unprivileged mode by setting `UNPRIVILEGED=1`, and the deploy script can recreate privileged if `/dev/kfd` permission denial is detected.

## Quick start

1. Ensure prox01 has:
   - Ubuntu 26.04 LXC template present.
   - AMD iGPU stack working on host.
   - /dev/dri and /dev/kfd present on host.
2. Run deploy from this directory:

   PROXMOX_SSH=root@prox01 ./deploy-hlh-ai-engine-dev.sh

   You can run this either from your workstation or directly on prox01.
   When run on prox01, the script automatically switches to local mode and avoids SSH/SCP to itself.

3. Verify:

   ssh root@prox01 "pct exec 110 -- verify-rocm-vllm"

## Optional overrides

You can override all defaults at runtime, for example:

CTID=110 TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst STORAGE=local-lvm PROXMOX_SSH=root@prox01 ./deploy-hlh-ai-engine-dev.sh

Disable automatic privileged fallback if you are actively testing unprivileged tuning:

AUTO_PRIVILEGED_FALLBACK=0 ./deploy-hlh-ai-engine-dev.sh

## Key files

- deploy-hlh-ai-engine-dev.sh: end-to-end orchestration from workstation to prox01 and CT bootstrap.
- scripts/prox01-create-lxc-110.sh: creates or reconciles CT config and GPU passthrough settings on prox01.
- scripts/in-ct-install-rocm-vllm.sh: installs ROCm userspace, amd-smi/rocm-smi tools, vLLM, and verification helpers.
- docs/OPERATIONS.md: troubleshooting and privilege fallback runbook.
