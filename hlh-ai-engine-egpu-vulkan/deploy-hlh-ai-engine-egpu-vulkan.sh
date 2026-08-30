#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/ansible/files/configure-ai-engine-inside-lxc.sh"

usage() {
	cat <<'EOF'
Usage:
	./deploy-hlh-ai-engine-egpu-vulkan.sh

This is the direct Proxmox bootstrap path (no OpenTofu):
	1) Detect eGPU PCI address via lspci (any card on OCuLink)
  2) Create privileged LXC 130 (hlh-ai-engine-egpu-vulkan)
  3) Add native Proxmox PCI passthrough for entire eGPU IOMMU group
  4) Start container
  5) Push/run in-container bootstrap script

NOTE: The LXC ONLY sees the eGPU — the iGPU (890M) is isolated by not being in
the same IOMMU group. The passthrough is card-agnostic: swap the GPU card and the
same PCI address will be used (it's the OCuLink connector's physical address).
EOF
}

LXC_ID=130
LXC_NAME="hlh-ai-engine-egpu-vulkan"
LXC_HOSTNAME="hlh-ai-engine-egpu-vulkan"
LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
POOL="RaidZ1-6TB"
MODEL_HOST_DIR="/srv/ai/models"
MODEL_LXC_DIR="/srv/ai/models"
LXC_ROOTFS_SIZE="64"
LXC_MEMORY="8192"
LXC_CORES="12"
LXC_IP_CONFIG="192.168.1.30/24"
LXC_GATEWAY="192.168.1.1"

# ─── eGPU Detection Helpers ────────────────────────────────────────────────────
# Detect the OCuLink-connected eGPU PCI address (any VGA/3D/display not on bus c6
# which is the iGPU/NPU). Returns the PCI address like "0000:c5:00.0".
detect_egpu_pci() {
  local egpu_pci
  # Find any VGA/3D/display controller NOT on bus c6 (iGPU/NPU) —
  # this catches the eGPU on the OCuLink connector regardless of card type.
  egpu_pci=$(lspci -D 2>/dev/null | grep -iE 'vga|3d controller|display' | grep -v '0000:c6:' | head -1 | awk '{print $1}')
  if [ -z "$egpu_pci" ]; then
    echo "ERROR: No eGPU detected via OCuLink. Is a GPU plugged in?" >&2
    exit 1
  fi
  echo "$egpu_pci"
}

# Get ALL devices in the eGPU's IOMMU group (GPU + companion devices like audio).
# These must all be passed through together — Proxmox enforces IOMMU group atomicity.
get_iommu_group_devices() {
  local pci="$1"
  local iommu_link
  iommu_link=$(readlink "/sys/bus/pci/devices/0000:$pci/iommu_group" 2>/dev/null)
  if [ -z "$iommu_link" ]; then
    echo "ERROR: Could not find IOMMU group for $pci" >&2
    exit 1
  fi
  ls "$iommu_link/devices/" 2>/dev/null
}

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

	printf '%s\n' 'Are you sure?  hlh-ai-engine-egpu-vulkan is already running and deployed!'
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
	--description "llama.cpp AI engine with Vulkan (generic eGPU via OCuLink), model storage on ${POOL}"

echo "[3/6] Detecting eGPU and adding native PCI passthrough..."
EGPU_PCI=$(detect_egpu_pci)
echo "  Detected eGPU PCI address: $EGPU_PCI"

IOMMU_DEVICES=$(get_iommu_group_devices "$EGPU_PCI")
echo "  IOMMU group devices (all will be passed through): $IOMMU_DEVICES"

# Add native Proxmox PCI passthrough for EVERY device in the IOMMU group.
# This is card-agnostic: any GPU plugged into the OCuLink dock will enumerate
# at the same physical PCIe address, and the entire IOMMU group is passed through
# so companion devices (audio, USB controllers if on the dock) are included too.
IDX=0
for dev in $IOMMU_DEVICES; do
  echo "  hostpci$IDX: host=0000:$dev" >> "/etc/pve/lxc/${LXC_ID}.conf"
  IDX=$((IDX + 1))
done
echo "  Added $IDX native PCI passthrough devices to LXC conf"

echo "[4/6] Starting LXC ${LXC_ID}..."
pct start "${LXC_ID}"
sleep 5

echo "[5/6] Running in-container bootstrap..."
pct exec "${LXC_ID}" -- mkdir -p /root/ai-engine-bootstrap
pct push "${LXC_ID}" "$BOOTSTRAP_SCRIPT" /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh --perms 0755
pct exec "${LXC_ID}" -- bash /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh

echo "[6/6] Deployment complete. LXC ${LXC_ID} (${LXC_NAME}) is running."
echo "Model storage: ${MODEL_HOST_DIR} (host) <-> ${MODEL_LXC_DIR} (container) on ${POOL}"
echo "Access llama-server at http://192.168.1.30:80"
