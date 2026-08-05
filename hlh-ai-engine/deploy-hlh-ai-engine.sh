#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/ansible/files/configure-ai-engine-inside-lxc.sh"

usage() {
	cat <<'EOF'
Usage:
	./deploy-hlh-ai-engine.sh

This is the direct Proxmox bootstrap path (no OpenTofu):
	1) Create privileged LXC 101 (hlh-ai-engine)
  2) Configure GPU passthrough
  3) Start container
  4) Push/run in-container bootstrap script
EOF
}

LXC_ID=101
LXC_NAME="hlh-ai-engine"
LXC_HOSTNAME="hlh-ai-engine"
LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
POOL="RaidZ1-6TB"
MODEL_HOST_DIR="/srv/ai/models"
MODEL_LXC_DIR="/srv/ai/models"
LXC_ROOTFS_SIZE="64"
LXC_MEMORY="49152"
LXC_CORES="12"
LXC_IP_CONFIG="192.168.1.12/24"
LXC_GATEWAY="192.168.1.1"
ROCM_VERSION="7.14.0"

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: Unknown option: $1" >&2
			usage
			exit 1
			;;
	esac
	shift
done

command -v pct >/dev/null 2>&1 || { echo "ERROR: pct command not found. Run on Proxmox host." >&2; exit 1; }
[[ -f "$BOOTSTRAP_SCRIPT" ]] || { echo "ERROR: Bootstrap script not found: $BOOTSTRAP_SCRIPT" >&2; exit 1; }

confirm_existing_lxc_delete() {
	local answer

	printf '%s\n' 'Are you sure?  hlh-ai-engine is already running and deployed!'
	printf '%s' 'Delete it and redeploy? [y/N] '
	read -r answer

	case "$answer" in
		y|Y|yes|YES)
			return 0
			;;
		*)
			echo "Aborted." >&2
			exit 1
			;;
	esac
}


echo "[1/6] Creating model storage directory on ${POOL}..."
mkdir -p "${MODEL_HOST_DIR}"
chown 0:0 "${MODEL_HOST_DIR}"
chmod 775 "${MODEL_HOST_DIR}"

if pct status "${LXC_ID}" >/dev/null 2>&1; then
	confirm_existing_lxc_delete
	echo "[1/6] Deleting existing LXC ${LXC_ID} so it can be redeployed..."
	pct stop "${LXC_ID}" >/dev/null 2>&1 || true
	pct destroy "${LXC_ID}" >/dev/null 2>&1 || pct delete "${LXC_ID}"
fi

echo "[2/6] Creating privileged Ubuntu LXC (${LXC_ID}, ${LXC_NAME}) on ${POOL}..."
pct create "${LXC_ID}" "${LXC_IMAGE}" \
	--storage "${POOL}" \
	--rootfs "${LXC_ROOTFS_SIZE}" \
	--hostname "${LXC_HOSTNAME}" \
	--memory "${LXC_MEMORY}" \
	--cores "${LXC_CORES}" \
	--features nesting=1,keyctl=1 \
	--net0 name=eth0,bridge=vmbr0,ip=${LXC_IP_CONFIG},gw=${LXC_GATEWAY} \
	--unprivileged 0 \
	--onboot 1 \
	--mp0 "${MODEL_HOST_DIR},mp=${MODEL_LXC_DIR}" \
	--description "llama.cpp AI engine with ROCm ${ROCM_VERSION}, model storage on ${POOL} (Qwen3-Coder-30B)"

echo "[3/6] Adding GPU/ROCm passthrough devices..."
cat >> "/etc/pve/lxc/${LXC_ID}.conf" <<'LXCCONF'

# GPU passthrough - DRI (render) + KFD (ROCm/HIP compute)
# KFD major on this host: 511
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 511:0 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
LXCCONF

echo "[4/6] Starting LXC ${LXC_ID}..."
pct start "${LXC_ID}"
sleep 5

echo "[5/6] Running in-container bootstrap..."
pct exec "${LXC_ID}" -- mkdir -p /root/ai-engine-bootstrap
pct push "${LXC_ID}" "$BOOTSTRAP_SCRIPT" /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh --perms 0755
pct exec "${LXC_ID}" -- bash /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh

echo "[6/6] Deployment complete. LXC ${LXC_ID} (${LXC_NAME}) is running."
echo "Model storage: ${MODEL_HOST_DIR} (host) <-> ${MODEL_LXC_DIR} (container) on ${POOL}"
echo "Access llama-server at http://<container-ip>:8080"
