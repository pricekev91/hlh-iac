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
UNPRIVILEGED="${UNPRIVILEGED:-0}"
TEMPLATE="${TEMPLATE:-local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"
ROCM_APT_CODENAME="${ROCM_APT_CODENAME:-noble}"
AUTO_PRIVILEGED_FALLBACK="${AUTO_PRIVILEGED_FALLBACK:-1}"

echo "==> Deploying CT ${CTID} on ${PROXMOX_SSH}"

LOCAL_MODE=0
if command -v pveversion >/dev/null 2>&1; then
	case "${PROXMOX_SSH}" in
		root@prox01|prox01|root@localhost|localhost|root@127.0.0.1|127.0.0.1)
			LOCAL_MODE=1
			;;
	esac
fi

if [[ "${LOCAL_MODE}" -eq 1 ]]; then
	echo "==> Local mode: running directly on Proxmox host"
	cp "${SCRIPT_DIR}/scripts/prox01-create-lxc-110.sh" /root/prox01-create-lxc-110.sh
else
	echo "==> Pushing host-side create script"
	scp -q "${SCRIPT_DIR}/scripts/prox01-create-lxc-110.sh" "${PROXMOX_SSH}:/root/prox01-create-lxc-110.sh"
fi

echo "==> Creating/configuring CT"
if [[ "${LOCAL_MODE}" -eq 1 ]]; then
	chmod +x /root/prox01-create-lxc-110.sh
	CTID="${CTID}" HOSTNAME="${HOSTNAME}" IP_CIDR="${IP_CIDR}" GATEWAY="${GATEWAY}" \
	DNS_PRIMARY="${DNS_PRIMARY}" DNS_SECONDARY="${DNS_SECONDARY}" BRIDGE="${BRIDGE}" \
	STORAGE="${STORAGE}" DISK_GB="${DISK_GB}" CORES="${CORES}" MEMORY_MB="${MEMORY_MB}" SWAP_MB="${SWAP_MB}" \
	UNPRIVILEGED="${UNPRIVILEGED}" TEMPLATE="${TEMPLATE}" \
	/root/prox01-create-lxc-110.sh
else
	ssh -q "${PROXMOX_SSH}" \
		"chmod +x /root/prox01-create-lxc-110.sh && \
		 CTID='${CTID}' HOSTNAME='${HOSTNAME}' IP_CIDR='${IP_CIDR}' GATEWAY='${GATEWAY}' \
		 DNS_PRIMARY='${DNS_PRIMARY}' DNS_SECONDARY='${DNS_SECONDARY}' BRIDGE='${BRIDGE}' \
		 STORAGE='${STORAGE}' DISK_GB='${DISK_GB}' CORES='${CORES}' MEMORY_MB='${MEMORY_MB}' SWAP_MB='${SWAP_MB}' \
		 UNPRIVILEGED='${UNPRIVILEGED}' TEMPLATE='${TEMPLATE}' \
		 /root/prox01-create-lxc-110.sh"
fi

echo "==> Pushing in-container installer"
if [[ "${LOCAL_MODE}" -eq 1 ]]; then
	cp "${SCRIPT_DIR}/scripts/in-ct-install-rocm-vllm.sh" /root/in-ct-install-rocm-vllm.sh
	pct push "${CTID}" /root/in-ct-install-rocm-vllm.sh /root/in-ct-install-rocm-vllm.sh
else
	scp -q "${SCRIPT_DIR}/scripts/in-ct-install-rocm-vllm.sh" "${PROXMOX_SSH}:/root/in-ct-install-rocm-vllm.sh"
	ssh -q "${PROXMOX_SSH}" "pct push ${CTID} /root/in-ct-install-rocm-vllm.sh /root/in-ct-install-rocm-vllm.sh"
fi

echo "==> Running ROCm + vLLM bootstrap inside CT ${CTID}"
if [[ "${LOCAL_MODE}" -eq 1 ]]; then
	pct exec "${CTID}" -- bash -lc "chmod +x /root/in-ct-install-rocm-vllm.sh && ROCM_APT_CODENAME='${ROCM_APT_CODENAME}' /root/in-ct-install-rocm-vllm.sh"
else
	ssh -q "${PROXMOX_SSH}" \
		"pct exec ${CTID} -- bash -lc 'chmod +x /root/in-ct-install-rocm-vllm.sh && ROCM_APT_CODENAME=\"${ROCM_APT_CODENAME}\" /root/in-ct-install-rocm-vllm.sh'"
fi

echo "==> Checking ROCm /dev/kfd access"
if [[ "${LOCAL_MODE}" -eq 1 ]]; then
	ROCM_CHECK_OUTPUT="$(pct exec "${CTID}" -- bash -lc "rocminfo 2>&1 | head -n 80" || true)"
else
	ROCM_CHECK_OUTPUT="$(ssh -q "${PROXMOX_SSH}" "pct exec ${CTID} -- bash -lc 'rocminfo 2>&1 | head -n 80'" || true)"
fi

if echo "${ROCM_CHECK_OUTPUT}" | grep -qi "Unable to open /dev/kfd read-write: Permission denied"; then
	if [[ "${UNPRIVILEGED}" == "1" && "${AUTO_PRIVILEGED_FALLBACK}" == "1" ]]; then
		echo "==> Unprivileged /dev/kfd permission denied detected; recreating CT ${CTID} as privileged"
		if [[ "${LOCAL_MODE}" -eq 1 ]]; then
			chmod +x /root/prox01-create-lxc-110.sh
			CTID="${CTID}" HOSTNAME="${HOSTNAME}" IP_CIDR="${IP_CIDR}" GATEWAY="${GATEWAY}" \
			DNS_PRIMARY="${DNS_PRIMARY}" DNS_SECONDARY="${DNS_SECONDARY}" BRIDGE="${BRIDGE}" \
			STORAGE="${STORAGE}" DISK_GB="${DISK_GB}" CORES="${CORES}" MEMORY_MB="${MEMORY_MB}" SWAP_MB="${SWAP_MB}" \
			UNPRIVILEGED="0" FORCE_RECREATE="1" TEMPLATE="${TEMPLATE}" \
			/root/prox01-create-lxc-110.sh
			pct push "${CTID}" /root/in-ct-install-rocm-vllm.sh /root/in-ct-install-rocm-vllm.sh
			pct exec "${CTID}" -- bash -lc "chmod +x /root/in-ct-install-rocm-vllm.sh && ROCM_APT_CODENAME='${ROCM_APT_CODENAME}' /root/in-ct-install-rocm-vllm.sh"
		else
			ssh -q "${PROXMOX_SSH}" \
				"chmod +x /root/prox01-create-lxc-110.sh && \
				 CTID='${CTID}' HOSTNAME='${HOSTNAME}' IP_CIDR='${IP_CIDR}' GATEWAY='${GATEWAY}' \
				 DNS_PRIMARY='${DNS_PRIMARY}' DNS_SECONDARY='${DNS_SECONDARY}' BRIDGE='${BRIDGE}' \
				 STORAGE='${STORAGE}' DISK_GB='${DISK_GB}' CORES='${CORES}' MEMORY_MB='${MEMORY_MB}' SWAP_MB='${SWAP_MB}' \
				 UNPRIVILEGED='0' FORCE_RECREATE='1' TEMPLATE='${TEMPLATE}' \
				 /root/prox01-create-lxc-110.sh"
			ssh -q "${PROXMOX_SSH}" "pct push ${CTID} /root/in-ct-install-rocm-vllm.sh /root/in-ct-install-rocm-vllm.sh"
			ssh -q "${PROXMOX_SSH}" "pct exec ${CTID} -- bash -lc 'chmod +x /root/in-ct-install-rocm-vllm.sh && ROCM_APT_CODENAME=\"${ROCM_APT_CODENAME}\" /root/in-ct-install-rocm-vllm.sh'"
		fi
	fi
fi

echo "==> Deployment complete"
echo "Next checks:"
if [[ "${LOCAL_MODE}" -eq 1 ]]; then
	echo "  pct exec ${CTID} -- rocminfo | head -n 40"
	echo "  pct exec ${CTID} -- amd-smi static || true"
	echo "  pct exec ${CTID} -- /opt/vllm-venv/bin/python -c \"import torch; print(torch.version.hip, bool(torch.version.hip) and torch.cuda.is_available())\""
else
	echo "  ssh ${PROXMOX_SSH} 'pct exec ${CTID} -- rocminfo | head -n 40'"
	echo "  ssh ${PROXMOX_SSH} 'pct exec ${CTID} -- amd-smi static || true'"
	echo "  ssh ${PROXMOX_SSH} 'pct exec ${CTID} -- /opt/vllm-venv/bin/python -c \"import torch; print(torch.version.hip, bool(torch.version.hip) and torch.cuda.is_available())\"'"
fi
