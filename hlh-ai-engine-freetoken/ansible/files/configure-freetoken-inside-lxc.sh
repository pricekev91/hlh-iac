#!/usr/bin/env bash
# configure-freetoken-inside-lxc.sh
# Version: 0.2.0
# Description: Bootstrap FreeToken AI engine + Open WebUI on Ubuntu 24.04 LXC with ROCm passthrough
# Target GPU: AMD Radeon 890M (gfx1150/Strix Halo) on Proxmox 9.x privileged LXC
# Runtime: FreeToken (FlashML MoE serving engine) via uv + Open WebUI (Qwen-Chat style)
# Requirements: Run as root inside privileged LXC with GPU passthrough and /srv/ai/models bind mount
# Changelog:
#   0.2.0 - Added Open WebUI on port 80, configured to connect to FreeToken on localhost:1919
#           - Built-in authentication enabled for Open WebUI
#           - Dual systemd services: freetoken (1919) + openwebui (80)
#   0.1.0 - Initial version: ROCm + uv + FreeToken + systemd service on port 1919

set -euo pipefail

# --- CONFIGURABLE ---
MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_FILE="Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf"
GFX_VERSION="11.5.0"   # gfx1150 native — rocBLAS 7.14.0 supports it
ROCM_PATH="/opt/rocm"
ROCM_VERSION="7.14.0"
FT_VERSION=""  # empty = latest
OPENWEBUI_REPO="https://github.com/open-webui/open-webui.git"
OPENWEBUI_DIR="/opt/open-webui"

# --- 1. BASE DEPENDENCIES ---
echo "[1/11] Installing base dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip python3-venv curl wget unzip ca-certificates gnupg \
  libopenblas-dev libssl-dev openssh-server \
  software-properties-common

# --- 1b. ADD ROCM 7.14.0 REPO ---
echo "[1b/11] Adding ROCm ${ROCM_VERSION} repository..."
mkdir -p /etc/apt/keyrings
wget -qO - https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg | \
  gpg --dearmor | tee /etc/apt/keyrings/amdrocm.gpg > /dev/null

tee /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable main
EOF

echo 'APT::Key::GPGCommand "/usr/bin/gpg";' > /etc/apt/apt.conf.d/99gpg-override

# Pin AMD repo over Ubuntu's bundled ROCm packages
tee /etc/apt/preferences.d/rocm-pin << 'PIN'
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 1001
PIN

# Remove Ubuntu's conflicting rocminfo
apt-get remove -y rocminfo 2>/dev/null || true

apt-get update
apt-get install -y --no-install-recommends \
  amdrocm7.14-gfx1150 \
  amdrocm-core-dev7.14-gfx1150

# Verify ROCm install
if ! command -v rocm-smi &>/dev/null && ! command -v rocm-smi2 &>/dev/null; then
  echo "ERROR: ROCm packages installed but rocm-smi not found" >&2
  ls -la /opt/rocm/bin/ 2>/dev/null || echo "ERROR: /opt/rocm/bin does not exist" >&2
  exit 1
fi

# Add root to render and video groups for GPU access
usermod -aG render root
usermod -aG video root

# Allow root SSH login
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF
systemctl enable ssh
systemctl restart ssh || systemctl restart sshd

# --- 1c. INSTALL Node.js 20.x (Open WebUI requires >= 20) ---
echo "[1c/11] Installing Node.js 20.x..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
node --version
npm --version

# --- 1d. INSTALL uv (Python package manager) ---
echo "[1d/11] Installing uv (Python package manager)..."
curl -LsSf https://astral.sh/uv/install.sh | sh 2>&1
echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null || { echo "ERROR: uv installation failed"; exit 1; }
uv --version

# --- 2. ROCm Environment Setup ---
echo "[2/11] Setting up ROCm environment..."
tee /etc/profile.d/rocm.env << EOF
export PATH=\$PATH:${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin
export LD_LIBRARY_PATH=${ROCM_PATH}/lib:\${LD_LIBRARY_PATH:-}
export ROCM_PATH=${ROCM_PATH}
export HIP_PATH=${ROCM_PATH}
export HSA_OVERRIDE_GFX_VERSION=${GFX_VERSION}
EOF

set +u
source /etc/profile.d/rocm.env
set -u

# --- 3. INSTALL FREETOKEN ---
echo "[3/11] Installing FreeToken via uv..."

# Create a virtual environment for FreeToken
FT_VENV="/opt/freetoken-venv"
mkdir -p "$FT_VENV"
uv venv "$FT_VENV"
source "$FT_VENV/bin/activate"

# Install FreeToken — [accel] is the correct extra name (not [rocm])
# ROCm acceleration is handled by the ROCm packages installed earlier
if command -v rocm-smi &>/dev/null || command -v rocm-smi2 &>/dev/null; then
  echo "ROCm GPU detected — installing freetoken with accel backend..."
  if [ -n "$FT_VERSION" ]; then
    uv pip install "freetoken[accel]==${FT_VERSION}"
  else
    uv pip install "freetoken[accel]"
  fi
else
  echo "No ROCm GPU detected — installing FreeToken CPU-only..."
  if [ -n "$FT_VERSION" ]; then
    uv pip install "freetoken==${FT_VERSION}"
  else
    uv pip install "freetoken"
  fi
fi

# Verify FreeToken install
if ! command -v ft &>/dev/null; then
  FT_BIN="$FT_VENV/bin/ft"
  if [ -f "$FT_BIN" ]; then
    ln -sf "$FT_BIN" /usr/local/bin/ft
  else
    echo "ERROR: FreeToken 'ft' command not found after installation" >&2
    exit 1
  fi
fi
echo "FreeToken installed: $(ft --version 2>/dev/null || echo 'version unknown')"

# --- 4. MODEL STORAGE & VERIFICATION ---
echo "[4/11] Checking model directory..."
mkdir -p "$MODEL_DIR"

if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  echo "Default model present: $DEFAULT_MODEL_FILE"
else
  echo "WARNING: Default model not found at ${MODEL_DIR}/${DEFAULT_MODEL_FILE}"
  mapfile -t EXISTING_MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' 2>/dev/null | sort)
  if [ "${#EXISTING_MODELS[@]}" -gt 0 ]; then
    echo "Found existing GGUF models:"
    for m in "${EXISTING_MODELS[@]}"; do echo "  - $m"; done
    echo "Will use first available model at startup"
  else
    echo "WARNING: No GGUF models found in $MODEL_DIR — FreeToken will start but have no model to serve"
  fi
fi

# --- 5. INSTALL OPEN WEBUI FROM GITHUB ---
echo "[5/11] Installing Open WebUI from GitHub..."

if [ -d "$OPENWEBUI_DIR/.git" ]; then
  echo "Open WebUI repository already exists — updating..."
  cd "$OPENWEBUI_DIR"
  git fetch --all
  git reset --hard origin/main 2>/dev/null || git reset --hard origin/master 2>/dev/null || true
else
  echo "Cloning Open WebUI repository..."
  git clone --depth=1 "$OPENWEBUI_REPO" "$OPENWEBUI_DIR"
fi

cd "$OPENWEBUI_DIR"

# Install Node.js dependencies and build
echo "Installing Open WebUI dependencies..."
if [ -f "pnpm-lock.yaml" ]; then
  npm install -g pnpm 2>&1 | tail -1
  pnpm install 2>&1
elif [ -f "package-lock.json" ]; then
  npm ci 2>&1 || npm install 2>&1
else
  echo "WARNING: No lock file found — running npm install..."
  npm install 2>&1
fi

echo "Building Open WebUI frontend..."
npm run build 2>&1 | tail -5

echo "Open WebUI installed at $OPENWEBUI_DIR"

# --- 6. FREETOKEN SYSTEMD SERVICE ---
echo "[6/11] Creating systemd service for FreeToken..."
cat > /etc/systemd/system/freetoken.service << UNIT
[Unit]
Description=FreeToken AI Engine (FlashML MoE serving engine)
After=network.target rocm-smi.service

[Service]
Type=simple
WorkingDirectory=/opt
Environment=HSA_OVERRIDE_GFX_VERSION=${GFX_VERSION}
Environment=PATH=${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin:/opt/freetoken-venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=${ROCM_PATH}/lib:${ROCM_PATH}/lib64
Environment=ROCM_PATH=${ROCM_PATH}
Environment=HIP_PATH=${ROCM_PATH}
ExecStart=/opt/freetoken-venv/bin/ft serve \
  --model /srv/ai/models/${DEFAULT_MODEL_FILE} \
  --host 0.0.0.0 --port 1919 \
  --gpu auto \
  --ctx-size 32768 \
  --batch-size 128 \
  --parallel 1
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT
echo "FreeToken service unit written"

# --- 7. OPEN WEBUI SYSTEMD SERVICE ---
echo "[7/11] Creating systemd service for Open WebUI..."
cat > /etc/systemd/system/openwebui.service << UNIT
[Unit]
Description=Open WebUI (AI Chat Interface)
After=network.target freetoken.service
Requires=freetoken.service

[Service]
Type=simple
WorkingDirectory=${OPENWEBUI_DIR}
Environment=PORT=80
Environment=HOSTNAME=0.0.0.0
Environment=WEBUI_AUTH=True
Environment=OPENAI_API_BASE_URL=http://localhost:1919/v1
Environment=OPENAI_API_KEY=freetoken-local-key
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin
Environment=NODE_ENV=production
ExecStart=${OPENWEBUI_DIR}/node_modules/.bin/node ${OPENWEBUI_DIR}/backend/main.py
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT
echo "Open WebUI service unit written"

# --- 8. MODEL SWITCH SCRIPT ---
echo "[8/11] Creating interactive model switcher..."
cat > /usr/local/bin/switch-freetoken-model.sh << 'EOS'
#!/usr/bin/env bash
# switch-freetoken-model.sh
# Version: 0.2.0
# Description: Interactive model switcher for FreeToken AI engine
# Usage: Run inside the FreeToken LXC as root
set -euo pipefail

MODEL_DIR="/srv/ai/models"
SERVICE="freetoken"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║               switch-freetoken-model.sh                          ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  FreeToken AI Engine — Model Switcher                            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Current state
CUR_MODEL=$(grep -- '--model ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model") print $(i+1)}') || CUR_MODEL="(not set)"
CUR_PORT=$(grep -- '--port ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--port") print $(i+1)}') || CUR_PORT="(not set)"
echo "  Currently active: $CUR_MODEL"
echo "  Port             : ${CUR_PORT:-1919}"
echo ""

# Model selection
mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "No .gguf models found in $MODEL_DIR."
  exit 1
fi

echo "Available models:"
for i in "${!MODELS[@]}"; do
  printf "  %2d) %s\n" $((i+1)) "$(basename "${MODELS[$i]}")"
done

read -rp "Select model number to activate: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODELS[@]} )); then
  echo "Invalid selection."
  exit 1
fi

NEW_MODEL="${MODELS[$((CHOICE-1))]}"
NEW_MODEL_BASE="$(basename "$NEW_MODEL")"

# Context size selection
echo ""
echo "Context size options:"
echo "   1) 32768  (32K)  — recommended, good balance"
echo "   2) 65536  (64K)  — full long-context"
echo "   3) 16384  (16K)  — quarter, saves VRAM"
echo "   4)  8192   (8K)  — minimal"
echo "   5) Custom         — enter manually"

read -rp "Select context size [default: 1]: " CTX_CHOICE
case "${CTX_CHOICE:-1}" in
  1) NEW_CTX=32768 ;;
  2) NEW_CTX=65536 ;;
  3) NEW_CTX=16384 ;;
  4) NEW_CTX=8192  ;;
  5)
    read -rp "Enter custom ctx-size: " NEW_CTX
    if ! [[ "$NEW_CTX" =~ ^[0-9]+$ ]]; then
      echo "Invalid ctx-size."
      exit 1
    fi
    ;;
  *) NEW_CTX=32768 ;;
esac

# Summary
echo ""
echo "  New model: $NEW_MODEL_BASE"
echo "  ctx-size : $NEW_CTX"
echo ""
read -rp "Apply and restart $SERVICE? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# Rewrite ExecStart
tmp_file="$(mktemp)"
cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"

awk -v model="$NEW_MODEL" -v ctx="$NEW_CTX" '
  BEGIN { in_block=0; done=0 }
  /^ExecStart=.*ft serve/ {
    done=1
    print "ExecStart=/opt/freetoken-venv/bin/ft serve \\"
    print "  --model " model " \\"
    print "  --host 0.0.0.0 --port 1919 \\"
    print "  --gpu auto \\"
    print "  --ctx-size " ctx " \\"
    print "  --batch-size 128 \\"
    print "  --parallel 1"
    in_block=1
    next
  }
  in_block {
    if (/^Restart=/) { in_block=0; print }
    next
  }
  { print }
  END { if (!done) exit 42 }
' "$SYSTEMD_SERVICE" > "$tmp_file" || {
  rm -f "$tmp_file"
  echo "ERROR: Failed to rewrite ExecStart" >&2
  exit 1
}

mv "$tmp_file" "$SYSTEMD_SERVICE"

systemctl daemon-reload
systemctl restart "$SERVICE"

# Wait for service to come up
HEALTH_URL="http://127.0.0.1:1919/health"
START_RESTARTS="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
OK=0
echo ""
echo "  Waiting for $SERVICE to load ($HEALTH_URL)..."
for i in {1..90}; do
  if curl -fsS -m 3 -o /dev/null "$HEALTH_URL" 2>/dev/null; then
    OK=1
    break
  fi
  NR="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
  ST="$(systemctl show -p ActiveState --value "$SERVICE" 2>/dev/null)"
  if [ "$ST" = "failed" ] || { [ -n "$NR" ] && [ "$NR" -gt "$START_RESTARTS" ]; }; then
    echo "  [✗] $SERVICE entered failed/crash-loop state (NRestarts=$NR)."
    break
  fi
  sleep 2
done

if [ "$OK" = "1" ]; then
  echo "  [✓] Switched to : $NEW_MODEL_BASE"
  echo "  [✓] ctx-size    : $NEW_CTX"
  echo "  [✓] Service     : $SERVICE running (health OK)"
  echo ""
  CONTAINER_IP="$(hostname -I | awk '{print $1}')"
  echo "  OpenAI API : http://$CONTAINER_IP:1919/v1/chat/completions"
  echo "  Anthropic  : http://$CONTAINER_IP:1919/v1/messages"
  echo "  Open WebUI : http://$CONTAINER_IP:80"
  echo "  Watch logs : journalctl -u $SERVICE -f"
  echo "  GPU usage  : rocm-smi"
else
  echo "  [✗] WARNING: $SERVICE did not start cleanly after switch!"
  echo "  Check logs with: journalctl -u $SERVICE -f"
  exit 1
fi
EOS
chmod +x /usr/local/bin/switch-freetoken-model.sh

# Also copy to model dir for convenience
cp /usr/local/bin/switch-freetoken-model.sh "${MODEL_DIR}/switch-freetoken-model.sh"
chmod +x "${MODEL_DIR}/switch-freetoken-model.sh"

# --- 9. ENABLE & START SERVICES ---
echo "[9/11] Enabling and starting services..."
systemctl daemon-reload
systemctl enable --now freetoken.service
systemctl enable --now openwebui.service
sleep 5

# --- 10. VERIFICATION ---
echo "[10/11] Verifying setup..."
echo ""
echo "[Service status]"
echo ""
systemctl status freetoken --no-pager 2>/dev/null || echo "FreeToken service not running"
echo ""
systemctl status openwebui --no-pager 2>/dev/null || echo "Open WebUI service not running"
echo ""

echo "[FreeToken version]"
ft --version 2>/dev/null || echo "ft --version not available"
echo ""

echo "[ROCm GPU status]"
rocm-smi 2>/dev/null || rocm-smi2 2>/dev/null || echo "rocm-smi not responding"
echo ""

echo "[Health check - FreeToken (1919)]"
if curl -fsS -m 3 http://localhost:1919/health 2>/dev/null; then
  echo ""
  echo "[✓] FreeToken is responding on port 1919"
else
  echo "[!] FreeToken health endpoint not yet available (may still be loading model)"
  echo "    Check logs: journalctl -u freetoken -f"
fi
echo ""

echo "[Health check - Open WebUI (80)]"
if curl -fsS -m 3 http://localhost:80/ 2>/dev/null | grep -q "html"; then
  echo "[✓] Open WebUI is responding on port 80"
else
  echo "[!] Open WebUI web interface not yet available (may still be starting)"
  echo "    Check logs: journalctl -u openwebui -f"
fi
echo ""

echo "[Bootstrap complete - v0.2.0]"
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  Open WebUI:        http://<container-ip>:80                │"
echo "  │  OpenAI API:        http://<container-ip>:1919/v1/          │"
echo "  │  Anthropic API:     http://<container-ip>:1919/v1/messages │"
echo "  │  GPU device:        gfx1150 (AMD Radeon 890M)              │"
echo "  │  ROCm version:      ${ROCM_VERSION}                        │"
echo "  │  Model switcher:    switch-freetoken-model.sh               │"
echo "  └─────────────────────────────────────────────────────────────┘"
