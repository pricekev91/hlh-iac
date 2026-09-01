#!/usr/bin/env bash
# configure-freetoken-inside-lxc.sh
# Version: 0.1.0
# Description: Bootstrap FreeToken AI engine on Ubuntu 24.04 LXC with ROCm passthrough
# Target GPU: AMD Radeon 890M (gfx1150/Strix Halo) on Proxmox 9.x privileged LXC
# Engine: FreeToken-ROCm fork (AMD ROCm native support)
# Requirements: Run as root inside privileged LXC with GPU passthrough and /srv/ai/models bind mount
# Changelog:
#   0.1.0 - Initial version based on FreeToken-ROCm fork

set -euo pipefail

# --- CONFIGURABLE ---
MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
FREETOKEN_REPO="https://github.com/Maxritz/FreeToken-ROCm.git"
FREETOKEN_DIR="/opt/freetoken"
SERVICE_NAME="freetoken"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
SWITCH_SCRIPT="/usr/local/bin/switch-model.sh"
GFX_VERSION="11.5.0"   # gfx1150 native — rocBLAS 7.14.0 supports it
ROCM_PATH="/opt/rocm"
ROCM_VERSION="7.14.0"
# FreeToken default port is 1919
FREETOKEN_PORT="1919"
# ROCm architecture for 890M (Strix Halo)
ROCM_ARCH="gfx1150"

# --- 1. BASE DEPENDENCIES ---
echo "[1/8] Installing base dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip python3-venv curl wget unzip \
  libopenblas-dev libssl-dev ca-certificates gnupg \
  openssh-server

# --- 1b. ADD ROCM 7.14.0 REPO ---
echo "[1/8] Adding ROCm ${ROCM_VERSION} repository..."
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
  amdrocm${ROCM_VERSION//./}-gfx1150 \
  amdrocm-core-dev${ROCM_VERSION//./}-gfx1150

# Verify HIP CMake package exists (needed for any HIP builds)
if [ ! -f /opt/rocm/lib/cmake/hip-lang/hip-lang-config.cmake ] && \
   [ ! -f /opt/rocm/lib64/cmake/hip-lang/hip-lang-config.cmake ] && \
   [ ! -f /opt/rocm/lib/x86_64-unknown-linux-gnu/cmake/hip-lang/hip-lang-config.cmake ]; then
  echo "ERROR: HIP CMake package not found after ROCm install (hip-lang-config.cmake)." >&2
  exit 1
fi

# Add root to render and video groups for GPU access
usermod -aG render root
usermod -aG video root

# Allow root SSH login with password for lab access
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF
systemctl enable ssh
systemctl restart ssh || systemctl restart sshd

# Install amdgpu-top via the upstream .deb release
echo "[1/8] Installing amdgpu-top (.deb release, no snapd required)..."
AMDGPU_TOP_VERSION="0.11.5"
AMDGPU_TOP_DEB="amdgpu-top_${AMDGPU_TOP_VERSION}-1_amd64.deb"
AMDGPU_TOP_URL="https://github.com/Umio-Yasuno/amdgpu_top/releases/download/v${AMDGPU_TOP_VERSION}/${AMDGPU_TOP_DEB}"
AMDGPU_TOP_TMP="/tmp/${AMDGPU_TOP_DEB}"

if command -v amdgpu_top >/dev/null 2>&1; then
  echo "amdgpu_top already installed: $(command -v amdgpu_top)"
else
  if wget -qO "$AMDGPU_TOP_TMP" "$AMDGPU_TOP_URL"; then
    apt-get install -y "$AMDGPU_TOP_TMP" || {
      echo "WARNING: amdgpu-top .deb install failed; continuing without it"
    }
    rm -f "$AMDGPU_TOP_TMP"
  else
    echo "WARNING: Failed to download amdgpu-top .deb; continuing without it"
  fi
fi

# --- ROCm Environment Setup ---
echo "[1/8] Setting up ROCm environment..."
tee /etc/profile.d/rocm.env << EOF
export PATH=\$PATH:${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin
export LD_LIBRARY_PATH=${ROCM_PATH}/lib:\${LD_LIBRARY_PATH:-}
export ROCM_PATH=${ROCM_PATH}
export HIP_PATH=${ROCM_PATH}
EOF

set +u
source /etc/profile.d/rocm.env
set -u

# --- 2. INSTALL UV (Python package manager) ---
echo "[2/8] Installing uv..."
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.cargo/bin:$PATH"
fi
# Ensure uv is in PATH for subsequent commands
export PATH="$HOME/.cargo/bin:$PATH"

# --- 3. CLONE AND INSTALL FREETOKEN-ROCm ---
echo "[3/8] Cloning FreeToken-ROCm fork..."
if [ ! -d "$FREETOKEN_DIR" ]; then
  git clone --depth=1 "$FREETOKEN_REPO" "$FREETOKEN_DIR"
fi

cd "$FREETOKEN_DIR"
git checkout -f main 2>/dev/null || true
git pull --ff-only

# --- 4. SET UP PYTHON ENVIRONMENT AND INSTALL FREETOKEN ---
echo "[4/8] Setting up Python environment and installing FreeToken with ROCm support..."

# ROCm environment variables for JIT compilation
export HIP_PATH="${ROCM_PATH}"
export TRITON_OVERRIDE_ARCH="${ROCM_ARCH}"
export TVM_FFI_ROCM_ARCH_LIST="${ROCM_ARCH}"
export PYTORCH_ROCM_ARCH="${ROCM_ARCH}"
export ROCM_SDK_TARGET_FAMILY="${ROCM_ARCH}"
export CC="${ROCM_PATH}/lib/llvm/bin/clang"
export HIP_DEVICE_LIB_PATH="${ROCM_PATH}/lib/llvm/amdgcn/bitcode"
export TVM_FFI_CACHE_DIR="/opt/freetoken/.tvm-ffi-cache"
export ROCM_HOME="${ROCM_PATH}"
export ROCM_PATH="${ROCM_PATH}"
export PATH="${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin:${PATH}"
export LD_LIBRARY_PATH="${ROCM_PATH}/lib:${ROCM_PATH}/lib64:${LD_LIBRARY_PATH:-}"

# Skip CUDA extensions - critical for ROCm build
export FREETOKEN_SKIP_CUDA_EXT="1"

# Use HIP for GGUF backend (default for ROCm fork)
export FT_GGUF_BACKEND="hip"

# Create virtual environment
uv venv --python 3.12 .venv
source .venv/bin/activate

# Install PyTorch with ROCm support first (from nightly wheels)
echo "[4/8] Installing PyTorch with ROCm ${ROCM_VERSION}..."
uv pip install --no-deps torch==2.15.0a0+rocm10.1.0a20260816 \
  --index-url https://rocm.nightlies.amd.com/whl-multi-arch/

# Install amd-torch-device for gfx1150
uv pip install --no-deps amd-torch-device-gfx1150 \
  --index-url https://rocm.nightlies.amd.com/whl-multi-arch/

# Install Triton for AMD
uv pip install triton-windows>=3.7.1.post27 \
  --index-url https://rocm.nightlies.amd.com/whl-multi-arch/ || \
  uv pip install triton>=3.7.1

# Install tvm-ffi
uv pip install apache-tvm-ffi==0.1.13.post3

# Install FreeToken itself without CUDA extensions
echo "[4/8] Installing FreeToken from source..."
uv pip install -e . --no-deps --no-build-isolation

# --- 5. MODEL STORAGE ---
echo "[5/8] Setting up model directory..."
mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"

ACTIVE_MODEL_FILE=""

if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
  echo "Default model already present: $ACTIVE_MODEL_FILE"
else
  # Check for any existing GGUF models
  mapfile -t EXISTING_MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' | sort)
  if [ "${#EXISTING_MODELS[@]}" -gt 0 ]; then
    ACTIVE_MODEL_FILE="${EXISTING_MODELS[0]}"
    echo "Using existing model from mounted storage: $ACTIVE_MODEL_FILE"
  else
    ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
    echo "No existing models found. Please download a model to $MODEL_DIR"
    echo "Example: wget -P $MODEL_DIR https://huggingface.co/bartowski/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
  fi
fi

# --- 6. SYSTEMD SERVICE ---
echo "[6/8] Creating systemd service for FreeToken..."
cat > "$SYSTEMD_SERVICE" << UNIT
[Unit]
Description=FreeToken AI Engine (ft serve) - OpenAI/Anthropic compatible API on port ${FREETOKEN_PORT}
After=network.target

[Service]
Type=simple
WorkingDirectory=${FREETOKEN_DIR}
Environment=HSA_OVERRIDE_GFX_VERSION=${GFX_VERSION}
Environment=PATH=${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=${ROCM_PATH}/lib:${ROCM_PATH}/lib64
Environment=ROCM_PATH=${ROCM_PATH}
Environment=HIP_PATH=${ROCM_PATH}
Environment=TRITON_OVERRIDE_ARCH=${ROCM_ARCH}
Environment=TVM_FFI_ROCM_ARCH_LIST=${ROCM_ARCH}
Environment=PYTORCH_ROCM_ARCH=${ROCM_ARCH}
Environment=CC=${ROCM_PATH}/lib/llvm/bin/clang
Environment=HIP_DEVICE_LIB_PATH=${ROCM_PATH}/lib/llvm/amdgcn/bitcode
Environment=TVM_FFI_CACHE_DIR=/opt/freetoken/.tvm-ffi-cache
Environment=FREETOKEN_SKIP_CUDA_EXT=1
Environment=FT_GGUF_BACKEND=hip
ExecStart=${FREETOKEN_DIR}/.venv/bin/ft serve \
  --model ${MODEL_DIR}/${ACTIVE_MODEL_FILE} \
  --host 0.0.0.0 --port ${FREETOKEN_PORT}
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT

# --- 7. MODEL SWITCH SCRIPT ---
echo "[7/8] Creating interactive model switcher: $SWITCH_SCRIPT..."
cat > "$SWITCH_SCRIPT" << 'EOS'
#!/usr/bin/env bash
# switch-model.sh for FreeToken
# Version: 1.0.0
# Description: Interactive model switcher for FreeToken ft serve service

set -euo pipefail

MODEL_DIR="/srv/ai/models"
SERVICE="freetoken"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"
FREETOKEN_PORT="1919"

# ─── Atomic ExecStart rewrite ──────────────────────────────────────────────────
rewrite_execstart() {
  local model="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"

  awk -v model="$model" '
    BEGIN { in_block=0; done=0 }
    /^ExecStart=.*ft serve/ {
      done=1
      print "ExecStart=/opt/freetoken/.venv/bin/ft serve \\"
      print "  --model " model " \\"
      print "  --host 0.0.0.0 --port 1919"
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
    echo "ERROR: Failed to rewrite ExecStart in $SYSTEMD_SERVICE" >&2
    exit 1
  }

  mv "$tmp_file" "$SYSTEMD_SERVICE"
  echo "INFO: Successfully updated service configuration"
}

# ─── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                      switch-model.sh (FreeToken)                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ─── Current state ─────────────────────────────────────────────────────────────
CUR_MODEL=$(grep -- '--model ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model") print $(i+1)}')
echo "  Model directory : $MODEL_DIR"
echo "  Currently active: $CUR_MODEL"
echo ""

# ─── Model selection ───────────────────────────────────────────────────────────
mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "No .gguf models found in $MODEL_DIR."
  exit 1
fi

echo "Available models:"
for i in "${!MODELS[@]}"; do
  printf "  %2d) %s\n" $((i+1)) "${MODELS[$i]}"
done

read -rp "Select model number to activate: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODELS[@]} )); then
  echo "Invalid selection."
  exit 1
fi
NEW_MODEL="${MODELS[$((CHOICE-1))]}"

# ─── Summary & confirm ─────────────────────────────────────────────────────────
echo ""
echo "  New model   : $NEW_MODEL"
echo "  Port        : $FREETOKEN_PORT"
echo ""
read -rp "Apply and restart $SERVICE? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ─── Rewrite ExecStart & restart ──────────────────────────────────────────────
rewrite_execstart "$NEW_MODEL"

systemctl daemon-reload
systemctl restart "$SERVICE"

# ─── Wait for service to come up ──────────────────────────────────────────────
HEALTH_URL="http://127.0.0.1:${FREETOKEN_PORT}/health"
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
  echo "  [✓] Switched to : $NEW_MODEL"
  echo "  [✓] Service     : $SERVICE running (health OK)"
  echo ""
  echo "  API ready at        : http://$(hostname -I | awk '{print $1}'):${FREETOKEN_PORT}"
  echo "  OpenAI endpoint     : http://$(hostname -I | awk '{print $1}'):${FREETOKEN_PORT}/v1/chat/completions"
  echo "  Anthropic endpoint  : http://$(hostname -I | awk '{print $1}'):${FREETOKEN_PORT}/v1/messages"
  echo "  Health check        : http://$(hostname -I | awk '{print $1}'):${FREETOKEN_PORT}/health"
  echo "  Watch logs with     : journalctl -u $SERVICE -f"
else
  echo "  [✗] WARNING: $SERVICE did not start cleanly after switch!"
  echo "  Check logs with: journalctl -u $SERVICE -f"
  exit 1
fi
EOS
chmod +x "$SWITCH_SCRIPT"

# Keep /srv/ai/models/switch-model.sh in sync
cp "$SWITCH_SCRIPT" "${MODEL_DIR}/switch-model.sh"
chmod +x "${MODEL_DIR}/switch-model.sh"

# --- 7b. MODEL DOWNLOAD HELPER (dl.sh) ---
echo "[7b/8] Creating model download helper: ${MODEL_DIR}/dl.sh..."
cat > "${MODEL_DIR}/dl.sh" << 'EOS'
#!/usr/bin/env bash
# dl.sh - HuggingFace model downloader with resume support
# Usage: dl.sh <huggingface-resolve-url>
URL="$1"
if [ -z "$URL" ]; then
    echo "Usage: $0 <huggingface-download-url>"
    exit 1
fi
OUT="$(basename "${URL%%\?*}")"
echo "=== HuggingFace Downloader ==="
echo "URL : $URL"
echo "OUT : $OUT"
echo
for attempt in {1..5}; do
    echo "[Attempt $attempt] Starting/resuming download..."
    curl -L -C - --fail --show-error --retry 3 --progress-bar -o "$OUT" "$URL" && {
        echo "[✓] Download completed: $OUT"
        exit 0
    }
    echo "[!] Attempt $attempt failed; retrying in 5s..."
    sleep 5
done
echo "[✗] Download failed after 5 attempts: $URL"
exit 1
EOS
chmod +x "${MODEL_DIR}/dl.sh"

# --- 8. ENABLE & START SERVICE ---
echo "[8/8] Enabling and starting $SERVICE_NAME..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# --- 9. VERIFICATION ---
echo "[9/9] Verifying setup..."
echo ""
echo "[rocm-smi output]"
rocm-smi || echo "rocm-smi not found or failed"
echo ""
echo "[FreeToken version]"
${FREETOKEN_DIR}/.venv/bin/ft --version || true
echo ""
echo "[Service status]"
systemctl status "$SERVICE_NAME" --no-pager
echo ""
echo "[Bootstrap complete - v0.1.0]"
echo "  FreeToken API         : http://<container-ip>:1919"
echo "  OpenAI endpoint       : http://<container-ip>:1919/v1/chat/completions"
echo "  Anthropic endpoint    : http://<container-ip>:1919/v1/messages"
echo "  Health check          : http://<container-ip>:1919/health"
echo "  Switch models with    : switch-model.sh"
echo "  GPU device            : gfx1150 (AMD Radeon 890M)"
echo "  ROCm version          : ${ROCM_VERSION}"
echo "  FreeToken source      : FreeToken-ROCm fork (Maxritz)"