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

CONF_FILE="/etc/pve/lxc/${CTID}.conf"

if pct status "${CTID}" >/dev/null 2>&1; then
  echo "CT ${CTID} already exists. Skipping pct create and applying config safeguards."
else
  pct create "${CTID}" "${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${MEMORY_MB}" \
    --swap "${SWAP_MB}" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}" \
    --nameserver "${DNS_PRIMARY}" \
    --searchdomain "mizertech.net" \
    --unprivileged "${UNPRIVILEGED}" \
    --features "nesting=1,keyctl=1"
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
echo "Unprivileged=${UNPRIVILEGED}, GPU passthrough mounts and device cgroup rules applied."
