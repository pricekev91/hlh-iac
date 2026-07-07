#!/usr/bin/env bash
set -euo pipefail

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
FORCE_RECREATE="${FORCE_RECREATE:-0}"

CONF_FILE="/etc/pve/lxc/${CTID}.conf"

case "${UNPRIVILEGED}" in
  1|true|TRUE|yes|YES) UNPRIVILEGED_NORM="1" ;;
  0|false|FALSE|no|NO) UNPRIVILEGED_NORM="0" ;;
  *)
    echo "Invalid UNPRIVILEGED value: ${UNPRIVILEGED}. Expected 0/1 or true/false." >&2
    exit 1
    ;;
esac

if ! pvesm status --enabled 1 --storage "${STORAGE}" >/dev/null 2>&1; then
  FALLBACK_STORAGE="$(pvesm status --enabled 1 --content rootdir | awk 'NR>1 {print $1; exit}')"
  if [[ -z "${FALLBACK_STORAGE}" ]]; then
    echo "Requested storage '${STORAGE}' does not exist and no enabled rootdir-capable storage was found." >&2
    echo "Set STORAGE explicitly to a valid LXC-capable storage and rerun." >&2
    exit 1
  fi
  echo "Requested storage '${STORAGE}' not found. Falling back to '${FALLBACK_STORAGE}'."
  STORAGE="${FALLBACK_STORAGE}"
fi

if [[ "${FORCE_RECREATE}" == "1" ]]; then
  if pct status "${CTID}" >/dev/null 2>&1; then
    echo "FORCE_RECREATE=1 set, destroying existing CT ${CTID}"
    pct stop "${CTID}" >/dev/null 2>&1 || true
    pct destroy "${CTID}" --purge 1
  fi
fi

if pct status "${CTID}" >/dev/null 2>&1; then
  echo "CT ${CTID} already exists. Skipping pct create and applying config safeguards."
else
  echo "Creating CT ${CTID} from template ${TEMPLATE} (unprivileged=${UNPRIVILEGED_NORM})"
  pct create "${CTID}" "${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${MEMORY_MB}" \
    --swap "${SWAP_MB}" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}" \
    --nameserver "${DNS_PRIMARY}" \
    --searchdomain "mizertech.net" \
    --unprivileged "${UNPRIVILEGED_NORM}"

  # Apply features separately for broader compatibility across pct versions.
  pct set "${CTID}" --features "nesting=1"
fi

if ! grep -q "lxc.cgroup2.devices.allow: c 226:\* rwm" "${CONF_FILE}"; then
  echo "lxc.cgroup2.devices.allow: c 226:* rwm" >> "${CONF_FILE}"
fi
if ! grep -q "lxc.cgroup2.devices.allow: c 235:\* rwm" "${CONF_FILE}"; then
  echo "lxc.cgroup2.devices.allow: c 235:* rwm" >> "${CONF_FILE}"
fi
if ! grep -q "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" "${CONF_FILE}"; then
  echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >> "${CONF_FILE}"
fi
if ! grep -q "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file" "${CONF_FILE}"; then
  echo "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file" >> "${CONF_FILE}"
fi

# Add secondary DNS inside container after first boot.
pct start "${CTID}" >/dev/null 2>&1 || true
pct exec "${CTID}" -- bash -lc "printf 'nameserver ${DNS_PRIMARY}\nnameserver ${DNS_SECONDARY}\n' > /etc/resolv.conf"

echo "CT ${CTID} configured: ${HOSTNAME} ${IP_CIDR}"
echo "Unprivileged=${UNPRIVILEGED_NORM}, GPU passthrough mounts and device cgroup rules applied."
