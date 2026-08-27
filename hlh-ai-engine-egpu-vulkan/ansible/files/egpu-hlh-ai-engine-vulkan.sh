#!/usr/bin/env bash
# egpu-hlh-ai-engine-vulkan.sh
# Version: 1.0.0-egpu
# Description: Helper to target the RX480 eGPU (Ellesmere/POLARIS10/gfx803 8GB) regardless of Vulkan index
# Usage:
#   egpu-hlh-ai-engine-vulkan.sh              # detect and show RX480 Vulkan device
#   egpu-hlh-ai-engine-vulkan.sh --device-only # print only "--device VulkanX" (for scripting)
#   egpu-hlh-ai-engine-vulkan.sh --apply       # patch ai-engine service to use RX480 and restart
# Also installed as: /srv/ai/models/egpu-hlh-ai-engine-vulkan.sh, egpu-hlh-ai-engine-vuklan.sh (typo alias), egpu-rx480.sh
# Detection order:
#   1) llama-server --list-devices line matching RX ?480|Ellesmere|POLARIS10|gfx803 (case-insensitive)
#   2) fallback: line with 8192 MiB (RX480 is 8GB, 890M iGPU varies)
#   3) fallback: first AMD/RADV device
set -euo pipefail
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"
LLAMA_BIN="/opt/llama.cpp/build/bin/llama-server"
MODE="show"
if [[ "${1:-}" == "--device-only" ]]; then MODE="device-only"; shift || true
elif [[ "${1:-}" == "--apply" ]]; then MODE="apply"; shift || true
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: egpu-hlh-ai-engine-vulkan.sh [OPTION]
  (no args)      Detect and show RX480 Vulkan device
  --device-only  Print only "--device VulkanX" for scripting
  --apply        Patch /etc/systemd/system/ai-engine.service ExecStart to pin --device to RX480 and restart
  --help         This help
Detection uses: llama-server --list-devices, matches RX 480 / Ellesmere / POLARIS10 / gfx803.
Both iGPU (890M gfx1150) and eGPU (RX480) are exposed via /dev/dri; this pins to the eGPU.
HELP
  exit 0
fi
mapfile -t VULKAN_LINES < <($LLAMA_BIN --list-devices 2>/dev/null | grep -E '^  Vulkan[0-9]+:' || true)
if [ "${#VULKAN_LINES[@]}" -eq 0 ]; then
  mapfile -t VULKAN_LINES < <(vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|deviceType' | head -20 || true)
  echo "WARNING: llama-server --list-devices returned 0 devices, trying vulkaninfo fallback" >&2
fi
if [ "${#VULKAN_LINES[@]}" -eq 0 ]; then
  echo "ERROR: No Vulkan devices found. Check /dev/dri passthrough and mesa-vulkan-drivers." >&2
  exit 1
fi
echo "Detected Vulkan devices:" >&2
for l in "${VULKAN_LINES[@]}"; do echo "  $l" >&2; done
RX_LINE=""
for l in "${VULKAN_LINES[@]}"; do
  if echo "$l" | grep -qiE 'RX ?480|Ellesmere|POLARIS10|gfx803'; then RX_LINE="$l"; break; fi
done
if [ -z "$RX_LINE" ]; then
  for l in "${VULKAN_LINES[@]}"; do
    if echo "$l" | grep -q '8192 MiB'; then RX_LINE="$l"; echo "INFO: No exact RX480 string match, using 8192 MiB fallback -> $l" >&2; break; fi
  done
fi
if [ -z "$RX_LINE" ]; then
  for l in "${VULKAN_LINES[@]}"; do
    if echo "$l" | grep -qiE 'AMD|RADV'; then RX_LINE="$l"; echo "INFO: Using first AMD/RADV fallback -> $l" >&2; break; fi
  done
fi
if [ -z "$RX_LINE" ]; then RX_LINE="${VULKAN_LINES[0]}"; echo "WARNING: No AMD match, using first device -> $RX_LINE" >&2; fi
RX_DEVICE=$(echo "$RX_LINE" | sed -n 's/^  \(Vulkan[0-9]\+\):.*/\1/p')
if [ -z "$RX_DEVICE" ]; then RX_DEVICE="Vulkan0"; echo "WARNING: Could not parse Vulkan id, defaulting to Vulkan0" >&2; fi
RX_INFO=$(echo "$RX_LINE" | cut -d: -f2- | sed 's/^ //')
echo "" >&2
echo "RX480 target: $RX_DEVICE — $RX_INFO" >&2
if [ "$MODE" == "device-only" ]; then echo "--device $RX_DEVICE"; exit 0; fi
if [ "$MODE" == "show" ]; then
  echo ""; echo "Use: --device $RX_DEVICE  (e.g. llama-server --device $RX_DEVICE --model ... )"
  echo "To pin ai-engine service: sudo $0 --apply"
  CUR_GPU=$(grep -- '--device ' "$SYSTEMD_SERVICE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="--device") print $(i+1)}' || echo "both (split)")
  echo "Current service GPU: ${CUR_GPU:-both (split)}"; exit 0
fi
if [ "$MODE" == "apply" ]; then
  if [ ! -f "$SYSTEMD_SERVICE" ]; then echo "ERROR: $SYSTEMD_SERVICE not found" >&2; exit 1; fi
  CUR_MODEL=$(grep -- '--model ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model") print $(i+1)}')
  CUR_CTX=$(grep -- '--ctx-size ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--ctx-size") print $(i+1)}' || echo "4096")
  CUR_KV_K=$(grep -- '--cache-type-k ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--cache-type-k") print $(i+1)}' || echo "q4_0")
  CUR_SPEC=$(grep -- '--spec-type ' "$SYSTEMD_SERVICE" | sed -n 's/.*--spec-type \([^ ]*\).*/\1/p' || true)
  SPEC_FLAGS=""; if [ -n "$CUR_SPEC" ]; then SPEC_FLAGS=$(grep -o -- '--spec-type[^\\]*' "$SYSTEMD_SERVICE" | head -1 | sed 's/ *\\$//' | xargs || true); fi
  GPU_FLAG="--device $RX_DEVICE"
  echo "Patching $SYSTEMD_SERVICE to pin $GPU_FLAG (keeping model=$CUR_MODEL ctx=$CUR_CTX kv=$CUR_KV_K)..." >&2
  tmp=$(mktemp); cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"
  awk -v gpu="$GPU_FLAG" 'BEGIN{in_block=0} /^ExecStart=.*llama-server/ {in_block=1; print; next} in_block { if (/--device /) { sub(/--device [^ \\]*/, gpu); in_block=0; print; next } if (/\\$/) { print; next } if (/^Restart=/) { print "  " gpu " \\"; in_block=0; print; next } print; next } {print}' "$SYSTEMD_SERVICE" > "$tmp" || { rm -f "$tmp"; echo "ERROR: awk rewrite failed" >&2; exit 1; }
  if ! grep -q -- '--device ' "$tmp"; then awk -v gpu="$GPU_FLAG" '{ if (/--parallel 1/) sub(/--parallel 1/, gpu " --parallel 1"); print }' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"; fi
  mv "$tmp" "$SYSTEMD_SERVICE"
  echo "Updated service ExecStart:" >&2; sed -n '/^ExecStart=.*llama-server/,/^Restart=/p' "$SYSTEMD_SERVICE" | head -n -1 | sed 's/^/  /' >&2
  systemctl daemon-reload; systemctl restart "$SERVICE"
  for i in {1..15}; do systemctl is-active --quiet "$SERVICE" && break; sleep 2; done
  if systemctl is-active --quiet "$SERVICE"; then echo "[✓] ai-engine now pinned to $RX_DEVICE ($RX_INFO)" >&2; echo "Web UI: http://$(hostname -I | awk '{print $1}'):80" >&2
  else echo "[✗] Service failed to start after pinning. Check journalctl -u $SERVICE -f" >&2; exit 1; fi
fi
