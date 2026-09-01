#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/ansible/files/configure-freetoken-inside-lxc.sh"

usage() {
	cat <<'EOF'
Usage:
	./deploy-hlh-ai-engine-freetoken.sh

This is the direct Proxmox bootstrap path (no OpenTofu):
	1) Nuke & recreate LXC 140 (hlh-ai-engine-freetoken)
	2) Configure ROCm GPU passthrough (890M iGPU)
	3) Start container
	4) Push/run in-container bootstrap script (FreeToken install + systemd service)

Options:
	-h|--help    Show this help message

EOF
}

LXC_ID=140
LXC_NAME="hlh-ai-engine-freetoken"
LXC_HOSTNAME="hlh-ai-engine-freetoken"
LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
POOL="RaidZ1-6TB"
MODEL_HOST_DIR="/srv/ai/models"
MODEL_LXC_DIR="/srv/ai/models"
LXC_ROOTFS_SIZE="64"
LXC_MEMORY="49152"
LXC_CORES="12"
LXC_IP_CONFIG="192.168.1.13/24"
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

	printf '%s\n' "WARNING: LXC ${LXC_ID} (${LXC_NAME}) already exists and is running!"
	printf '%s\n' "This script will NUKE and REDEPLOY it — all data will be preserved via /srv/ai/models mount,"
	printf '%s\n' "but the container's root filesystem will be destroyed and recreated."
	printf '%s' 'Delete and redeploy? [y/N] '
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

echo "============================================================"
echo "  FreeToken AI Engine — LXC ${LXC_ID} (${LXC_NAME})"
echo "  Deploying on prox01 | ROCm ${ROCM_VERSION} | 890M iGPU"
echo "============================================================"
echo ""

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
	--description "FreeToken AI engine with ROCm ${ROCM_VERSION}, model storage on ${POOL}"

echo "[3/6] Adding ROCm GPU passthrough devices (890M iGPU)..."
# Same GPU passthrough as LXC 101 (hlh-ai-engine):
# Only the 890M iGPU (gfx1150): card1 (226:1) + renderD129 (226:129)
# RX 480 eGPU (gfx803) nodes are intentionally excluded so ROCm cannot
# enumerate the unsupported device as GPU 0 and fail the entire init chain.
# KFD is shared (511:0) but ROCm only sees GPUs that have a visible renderD.
cat >> "/etc/pve/lxc/${LXC_ID}.conf" <<'LXCCONF'

# GPU passthrough - 890M iGPU only (gfx1150/Strix Halo)
# RX 480 eGPU (gfx803) excluded: ROCm 7.x drops gfx803 and errors out
# when it appears as GPU 0, preventing the 890M from ever being reached.
# cgroup allow: only card1 (226:1) and renderD129 (226:129)
lxc.cgroup2.devices.allow: c 226:1 rwm
lxc.cgroup2.devices.allow: c 226:129 rwm
lxc.cgroup2.devices.allow: c 511:0 rwm
# Mount empty /dev/dri dir, then the specific 890M nodes only
lxc.mount.entry: none dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/dri/card1 dev/dri/card1 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD129 dev/dri/renderD129 none bind,optional,create=file
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
LXCCONF

echo "[4/6] Starting LXC ${LXC_ID}..."
pct start "${LXC_ID}"
sleep 5

echo "[5/6] Running in-container bootstrap (FreeToken install)..."
echo "  This will take 10-25 minutes (compiling ROCm kernels, installing Python packages)..."
pct exec "${LXC_ID}" -- mkdir -p /root/freetoken-bootstrap
pct push "${LXC_ID}" "$BOOTSTRAP_SCRIPT" /root/freetoken-bootstrap/configure-freetoken-inside-lxc.sh --perms 0755
pct exec "${LXC_ID}" -- bash /root/freetoken-bootstrap/configure-freetoken-inside-lxc.sh

echo "[6/6] Deployment complete. LXC ${LXC_ID} (${LXC_NAME}) is running."
echo ""
echo "  Model storage: ${MODEL_HOST_DIR} (host) <-> ${MODEL_LXC_DIR} (container) on ${POOL}"
echo "  FreeToken API : http://192.168.1.13:1919/v1/chat/completions"
echo "  Anthropic API : http://192.168.1.13:1919/v1/messages"
echo ""
