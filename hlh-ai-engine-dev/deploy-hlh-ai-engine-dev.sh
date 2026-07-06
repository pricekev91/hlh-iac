#!/usr/bin/env bash
set -euo pipefail

# End-to-end deployment entrypoint from local workstation.
# This script pushes and runs scripts on prox01 for CT 110.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROXMOX_SSH="${PROXMOX_SSH:-root@prox01}"
CTID="${CTID:-110}"
HOSTNAME="${HOSTNAME:-hlh-ai-engine-dev.mizertech.net}"
IP_CIDR="${IP_CIDR:-192.168.1.16/24}"
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS_PRIMARY="${DNS_PRIMARY:-192.168.1.1}"
DNS_SECONDARY="${DNS_SECONDARY:-192.168.1.2}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
DISK_GB="${DISK_GB:-64}"
CORES="${CORES:-12}"
MEMORY_MB="${MEMORY_MB:-55296}"
SWAP_MB="${SWAP_MB:-4096}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
TEMPLATE="${TEMPLATE:-local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"
ROCM_APT_CODENAME="${ROCM_APT_CODENAME:-noble}"

echo "==> Deploying CT ${CTID} on ${PROXMOX_SSH}"

echo "==> Pushing host-side create script"
scp -q "${SCRIPT_DIR}/scripts/prox01-create-lxc-110.sh" "${PROXMOX_SSH}:/root/prox01-create-lxc-110.sh"

echo "==> Creating/configuring CT"
ssh -q "${PROXMOX_SSH}" \
	"chmod +x /root/prox01-create-lxc-110.sh && \
	 CTID='${CTID}' HOSTNAME='${HOSTNAME}' IP_CIDR='${IP_CIDR}' GATEWAY='${GATEWAY}' \
	 DNS_PRIMARY='${DNS_PRIMARY}' DNS_SECONDARY='${DNS_SECONDARY}' BRIDGE='${BRIDGE}' \
	 STORAGE='${STORAGE}' DISK_GB='${DISK_GB}' CORES='${CORES}' MEMORY_MB='${MEMORY_MB}' SWAP_MB='${SWAP_MB}' \
	 UNPRIVILEGED='${UNPRIVILEGED}' TEMPLATE='${TEMPLATE}' \
	 /root/prox01-create-lxc-110.sh"

echo "==> Pushing in-container installer"
ssh -q "${PROXMOX_SSH}" "pct push ${CTID} /root/prox01-create-lxc-110.sh /root/.placeholder-from-host.sh >/dev/null 2>&1 || true"
scp -q "${SCRIPT_DIR}/scripts/in-ct-install-rocm-vllm.sh" "${PROXMOX_SSH}:/root/in-ct-install-rocm-vllm.sh"
ssh -q "${PROXMOX_SSH}" "pct push ${CTID} /root/in-ct-install-rocm-vllm.sh /root/in-ct-install-rocm-vllm.sh"

echo "==> Running ROCm + vLLM bootstrap inside CT ${CTID}"
ssh -q "${PROXMOX_SSH}" \
	"pct exec ${CTID} -- bash -lc 'chmod +x /root/in-ct-install-rocm-vllm.sh && ROCM_APT_CODENAME=\"${ROCM_APT_CODENAME}\" /root/in-ct-install-rocm-vllm.sh'"

echo "==> Deployment complete"
echo "Next checks:"
echo "  ssh ${PROXMOX_SSH} 'pct exec ${CTID} -- rocminfo | head -n 40'"
echo "  ssh ${PROXMOX_SSH} 'pct exec ${CTID} -- amd-smi static || true'"
echo "  ssh ${PROXMOX_SSH} 'pct exec ${CTID} -- /opt/vllm-venv/bin/python -c \"import torch; print(torch.cuda.is_available())\"'"
