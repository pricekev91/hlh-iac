#!/usr/bin/env bash
# configure-ai-engine-inside-lxc.sh
# Version: 1.0.2
# Description: Bootstrap llama.cpp AI engine on Ubuntu 24.04 LXC with Vulkan passthrough
# Target GPU: AMD Radeon 890M (gfx1150/Strix Halo) on Proxmox 9.x privileged LXC
# Requirements: Run as root inside privileged LXC with GPU passthrough and /srv/ai/models bind mount
# Changelog:
#   1.0.2 - Use common service name "ai-engine" (matches hlh-ai-engine) so the
#            shared hlh-switch-model.sh works regardless of host/CT
#   1.0.1 - Fix cmake configure failure: add spirv-headers (SPIRV-Headers CMake config)
#            and glslang-tools (glslangValidator) to base dependencies
#   1.0.0 - Vulkan rewrite: drop ROCm/HIP entirely, build llama.cpp with
#            GGML_VULKAN=ON, install Mesa Vulkan stack (RADV), verify via vulkaninfo.
#            /dev/kfd passthrough no longer required; /dev/dri only.
#   0.8.3 - switch-model.sh v1.4.2: added 72K (73728) and 96K (98304) ctx-size options
#            VRAM budget table updated with 72K and 96K KV cache estimates

set -euo pipefail

# --- CONFIGURABLE ---
MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-32B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
SERVICE_NAME="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
SWITCH_SCRIPT="/usr/local/bin/switch-model.sh"

# --- 1. BASE DEPENDENCIES ---
echo "[1/7] Installing base dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip \
  libopenblas-dev libssl-dev ca-certificates gnupg \
  openssh-server \
  libvulkan1 libvulkan-dev mesa-vulkan-drivers vulkan-tools glslc \
  spirv-headers glslang-tools

# Add root to render and video groups for GPU access
usermod -aG render root
usermod -aG video root

# Allow root SSH login with password for lab access.
# The root password is set manually after deploy.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF
systemctl enable ssh
systemctl restart ssh || systemctl restart sshd

# Install amdgpu-top via the upstream .deb release (works in LXC; snapd/AppArmor
# do not function reliably in unprivileged/container environments).
echo "[1/7] Installing amdgpu-top (.deb release, no snapd required)..."
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

# --- Pre-Build Checks ---
echo "[1/7] Verifying Vulkan setup..."
vulkaninfo --summary | head -20 || { echo "ERROR: vulkaninfo failed. Check /dev/dri passthrough and mesa-vulkan-drivers."; exit 1; }

# --- 2. BUILD LLAMA.CPP (Vulkan only) ---
echo "[2/7] Cloning and building llama.cpp (Vulkan)..."
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi

cd "$LLAMA_CPP_DIR"

cmake -S . -B build \
  -DGGML_VULKAN=ON \
  -DGGML_HIP=OFF \
  -DGGML_CUDA=OFF \
  -DCMAKE_BUILD_TYPE=Release

echo "[2/7] Building... (this can take 10-25 minutes with 12 cores)"
cmake --build build --config Release -j$(nproc)

# --- 3. MODEL STORAGE & DOWNLOAD ---
echo "[3/7] Setting up model directory..."
mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"

ACTIVE_MODEL_FILE=""

if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
  echo "Default model already present: $ACTIVE_MODEL_FILE"
else
  PREFERRED_MODELS=(
    "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    "Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
    "Qwen_Qwen3-Coder-Next-Q4_K_M.gguf"
  )
  for MODEL_CANDIDATE in "${PREFERRED_MODELS[@]}"; do
    if [ -f "${MODEL_DIR}/${MODEL_CANDIDATE}" ]; then
      ACTIVE_MODEL_FILE="$MODEL_CANDIDATE"
      echo "Using preferred existing model from mounted storage: $ACTIVE_MODEL_FILE"
      break
    fi
  done

  if [ -z "${ACTIVE_MODEL_FILE}" ]; then
    mapfile -t EXISTING_MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' | sort)
    if [ "${#EXISTING_MODELS[@]}" -gt 0 ]; then
      ACTIVE_MODEL_FILE="${EXISTING_MODELS[0]}"
      echo "Using existing model from mounted storage: $ACTIVE_MODEL_FILE"
    else
      ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
      echo "No existing models found; downloading default model: $ACTIVE_MODEL_FILE"
      wget -O "${MODEL_DIR}/${ACTIVE_MODEL_FILE}" "$DEFAULT_MODEL_URL"
    fi
  fi
fi

# --- 4. SYSTEMD SERVICE ---
echo "[4/7] Creating systemd service for llama-server..."
cat > "$SYSTEMD_SERVICE" << UNIT
[Unit]
Description=llama.cpp AI Engine (llama-server) - native web UI on port 80
After=network.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_CPP_DIR}/build/bin
ExecStart=${LLAMA_CPP_DIR}/build/bin/llama-server \
  --model ${MODEL_DIR}/${ACTIVE_MODEL_FILE} \
  --host 0.0.0.0 --port 80 \
  --ctx-size 4096 \
  -ngl 48 \
  --batch-size 128 \
  --parallel 1 \
  --cache-type-k q4_0 \
  --cache-type-v q4_0
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT

# --- 5. MODEL SWITCH SCRIPT ---
echo "[5/7] Creating interactive model switcher: $SWITCH_SCRIPT..."
cat > "$SWITCH_SCRIPT" << 'EOS'
#!/usr/bin/env bash
# switch-model.sh
# Version: 1.6.0
# Description: Interactive model switcher for llama.cpp ai-engine service
# Supports: model selection, ctx-size, KV cache quantization, speculative decoding (MTP/ngram), GPU selection
# Changelog:
#   1.6.0 - Added mandatory GPU selection menu (force single GPU to avoid multi-GPU bandwidth tank on 890M)
#   1.5.0 - Added full ngram speculative decoding menu (ngram-mod, ngram-map-k4v,
#            ngram-map-k, ngram-simple) for non-MTP models; tunable ngram-mod params
#   1.4.2 - Added 72K / 96K ctx-size options + VRAM table rows
#            Shows current model, ctx-size, and KV cache state on launch
#   1.3.0 - Auto-detect MTP models by filename (case-insensitive 'MTP' match)
#            Toggle --spec-type draft-mtp / --spec-draft-n-max / --parallel 1
#            Replaced fragile sed patching with atomic awk ExecStart rewrite
#            Model list annotates MTP entries with [MTP] tag
#            Banner shows current MTP mode
#   1.4.0 - Remove turboquant menu option until llama.cpp supports it in main
#   1.4.1 - Fixed triple-nested rewrite_execstart bug (function was never callable)
#            Added startup wait loop and web UI URL confirmation after switch
#   1.4.2 - Added 72K / 96K ctx-size options + VRAM table rows

set -euo pipefail

MODEL_DIR="/srv/ai/models"
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"
MTP_DRAFT_N_MAX="${MTP_DRAFT_N_MAX:-3}"

# ngram-mod tuning defaults (match llama.cpp build defaults)
NGRAM_N_MATCH="${NGRAM_N_MATCH:-24}"
NGRAM_N_MIN="${NGRAM_N_MIN:-48}"
NGRAM_N_MAX="${NGRAM_N_MAX:-64}"

# ─── MTP Detection ─────────────────────────────────────────────────────────────
is_mtp_model() {
  [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]
}

# ─── Atomic ExecStart rewrite ──────────────────────────────────────────────────
# Rewrites the full ExecStart block in the systemd unit with all chosen params.
# Handles both single-line and multi-line (backslash-continued) ExecStart formats.
rewrite_execstart() {
  local model="$1" ctx="$2" kv="$3" spec_flags="$4" gpu_flag="$5"
  local tmp_file
  tmp_file="$(mktemp)"

  cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"

  awk -v model="$model" -v ctx="$ctx" -v kv="$kv" -v spec_flags="$spec_flags" -v gpu_flag="$gpu_flag" '
    BEGIN { in_block=0; done=0 }
    /^ExecStart=.*llama-server/ && !in_block {
      done=1
      print "ExecStart=/opt/llama.cpp/build/bin/llama-server \\"
      print "  --model " model " \\"
      print "  --host 0.0.0.0 --port 80 \\"
      print "  --ctx-size " ctx " \\"
      print "  -ngl 48 \\"
      print "  --batch-size 128 \\"
      print "  --cache-type-k " kv " \\"
      if (spec_flags != "") {
        print "  --cache-type-v " kv " \\"
        print "  " spec_flags " \\"
        if (gpu_flag != "") {
          print "  " gpu_flag " \\"
        }
        print "  --parallel 1"
      } else {
        print "  --cache-type-v " kv " \\"
        if (gpu_flag != "") {
          print "  " gpu_flag " \\"
        }
        print "  --parallel 1"
      }
      in_block=1
      next
    }
    in_block {
      # Skip continuation lines (ending with \) and any lines until Restart=
      if (/\\$/) { next }
      if (/^Restart=/) { in_block=0; print; next }
      next
    }
    { print }
    END { if (!done) exit 42 }
  ' "$SYSTEMD_SERVICE" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "ERROR: Failed to rewrite ExecStart in $SYSTEMD_SERVICE" >&2
    echo "Service file may be corrupted or missing" >&2
    exit 1
  }

  mv "$tmp_file" "$SYSTEMD_SERVICE"
  echo "INFO: Successfully updated service configuration"
}

# ─── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                      switch-model.sh                             ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  VRAM BUDGET REFERENCE  (model weights + KV cache = total need)  ║"
echo "║                                                                  ║"
echo "║  Model Weights (fixed, loaded once):                             ║"
echo "║    70B Q2_K      ~17 GB   70B Q3_K_M   ~26 GB                    ║"
echo "║    70B Q4_K_M    ~38 GB   70B Q6_K     ~54 GB                    ║"
echo "║    35B Q4_K_M    ~21 GB   35B Q5_K_M   ~25 GB                    ║"
echo "║                                                                  ║"
echo "║  KV Cache (added on top — scales with ctx size):                 ║"
echo "║                  KV q4_0    KV q6_0    KV q8_0                   ║"
echo "║    96K context   ~12 GB     ~18 GB     ~24 GB                    ║"
echo "║    72K context   ~ 9 GB     ~14 GB     ~18 GB                    ║"
echo "║    64K context   ~ 8 GB     ~12 GB     ~18 GB                    ║"
echo "║    32K context   ~ 4 GB      ~ 6 GB     ~ 9 GB                    ║"
echo "║    16K context   ~ 2 GB      ~ 3 GB     ~ 5 GB                    ║"
echo "║     8K context   ~ 1 GB      ~ 2 GB     ~ 3 GB                    ║"
echo "║                                                                  ║"
echo "║  Example: 70B Q4_K_M (~38 GB) + 64K q8_0 (~18 GB) = ~56 GB       ║"
echo "║           70B Q4_K_M (~38 GB) + 64K q4_0 (~ 8 GB) = ~46 GB       ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ─── Current state ─────────────────────────────────────────────────────────────
CUR_MODEL=$(grep -- '--model '         "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model")         print $(i+1)}')
CUR_CTX=$(  grep -- '--ctx-size '      "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--ctx-size")      print $(i+1)}') || CUR_CTX="(not set)"
CUR_KV_K=$( grep -- '--cache-type-k '  "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--cache-type-k")  print $(i+1)}') || CUR_KV_K="(not set)"
CUR_KV_V=$( grep -- '--cache-type-v '  "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--cache-type-v")  print $(i+1)}') || CUR_KV_V="(not set)"
CUR_SPEC=$( grep -- '--spec-type '     "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--spec-type")     print $(i+1)}') || CUR_SPEC="none"
CUR_SPEC="${CUR_SPEC:-none}"
CUR_GPU=$(grep -- '--gpu '             "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--gpu")     print $(i+1)}') || CUR_GPU="both (split)"

echo "  Model directory : $MODEL_DIR"
echo "  Currently active: $CUR_MODEL"
echo "  ctx-size        : ${CUR_CTX:-(not set)}"
echo "  KV cache (K/V)  : ${CUR_KV_K} / ${CUR_KV_V}"
echo "  Spec decode     : $CUR_SPEC"
echo "  GPU             : $CUR_GPU"
echo ""

# ─── Model selection ───────────────────────────────────────────────────────────
mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "No .gguf models found in $MODEL_DIR."
  exit 1
fi

echo "Available models:"
for i in "${!MODELS[@]}"; do
  if is_mtp_model "${MODELS[$i]}"; then
    printf "  %2d) %s  [MTP]\n" $((i+1)) "${MODELS[$i]}"
  else
    printf "  %2d) %s\n" $((i+1)) "${MODELS[$i]}"
  fi
done

read -rp "Select model number to activate: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODELS[@]} )); then
  echo "Invalid selection."
  exit 1
fi
NEW_MODEL="${MODELS[$((CHOICE-1))]}"

# ─── Context size selection ────────────────────────────────────────────────────
echo ""
echo "Context size options:"
echo "   1) 98304  (96K)  — maximum long-context"
echo "   2) 73728  (72K)  — extended long-context"
echo "   3) 65536  (64K)  — full long-context"
echo "   4) 32768  (32K)  — half, saves ~50% KV VRAM"
echo "   5) 16384  (16K)  — quarter, minimal KV usage"
echo "   6)  8192   (8K)  — minimal, maximum VRAM headroom"
echo "   7) Custom         — enter manually"

read -rp "Select context size [default: 65536]: " CTX_CHOICE
case "${CTX_CHOICE:-3}" in
  1) NEW_CTX=98304  ;;
  2) NEW_CTX=73728  ;;
  3) NEW_CTX=65536  ;;
  4) NEW_CTX=32768  ;;
  5) NEW_CTX=16384  ;;
  6) NEW_CTX=8192   ;;
  7)
    read -rp "Enter custom ctx-size: " NEW_CTX
    if ! [[ "$NEW_CTX" =~ ^[0-9]+$ ]]; then
      echo "Invalid ctx-size."
      exit 1
    fi
    ;;
  *) NEW_CTX=65536 ;;
esac

# ─── KV cache quantization selection ──────────────────────────────────────────
echo ""
echo "KV cache quantization (applies to both K and V cache):"
echo "   1) q8_0  — highest quality,  ~2x VRAM vs q4  (safe floor for quality)"
echo "   2) q6_0  — very good quality, ~1.5x VRAM vs q4"
echo "   3) q4_0  — recommended,       lowest VRAM,    minimal quality loss"
echo ""
echo "   Recommendation for 64K context: q4_0 (saves 8-10 GB vs q8_0)"
echo "   Minimum recommended: q4_0 — going lower risks attention degradation"

read -rp "Select KV cache quant [default: q4_0]: " KV_CHOICE
case "${KV_CHOICE:-3}" in
  1) NEW_KV="q8_0" ;;
  2) NEW_KV="q6_0" ;;
  3) NEW_KV="q4_0" ;;
  *) NEW_KV="q4_0" ;;
esac

# ─── GPU selection ──────────────────────────────────────────────────────────────
  echo ""
  echo "GPU selection (FORCE single GPU — multi-GPU splits layers and tanks tok/s on bandwidth-starved iGPU):"
  echo "   1) GPU 0 only  — 890M iGPU (recommended for single-GPU speed)"
  echo "   2) GPU 1 only  — eGPU (RX 480 / MI60 when present)"
  echo "   3) Both GPUs   — split layers across both (default llama.cpp behavior, SLOW on 890M)"
  echo ""
  read -rp "Select GPU [default: 1]: " GPU_CHOICE
  case "${GPU_CHOICE:-1}" in
    1) GPU_FLAG="--gpu 0" ;;
    2) GPU_FLAG="--gpu 1" ;;
    3) GPU_FLAG="" ;;
    *) GPU_FLAG="--gpu 0" ;;
  esac

  # ─── Speculative decoding method selection ────────────────────────────────────
  if is_mtp_model "$NEW_MODEL"; then
    NEW_MTP="yes"
    MTP_INFO="--spec-type draft-mtp --spec-draft-n-max $MTP_DRAFT_N_MAX --parallel 1"
    DEFAULT_SPEC=1
    echo ""
    echo "Speculative decoding method:"
    echo "   1) MTP draft     — use the model's MTP heads (default, n-max $MTP_DRAFT_N_MAX)"
    echo "   2) ngram-mod     — n-gram matching, self-speculative (tunable)"
    echo "   3) ngram-map-k4v — n-gram keys + 4 m-gram values (fast self-speculation)"
    echo "   4) ngram-map-k   — n-gram keys only"
    echo "   5) ngram-simple  — simple n-gram lookup"
    echo "   6) none (standard) — disable speculative decoding"

    read -rp "Select method [default: $DEFAULT_SPEC]: " SPEC_CHOICE
    case "${SPEC_CHOICE:-$DEFAULT_SPEC}" in
      1)
        NEW_METHOD="draft-mtp"
        SPEC_FLAGS="--spec-type draft-mtp --spec-draft-n-max $MTP_DRAFT_N_MAX"
        ;;
      2)
        NEW_METHOD="ngram-mod"
        read -rp "  Customize ngram-mod params? [y/N]: " NGRAM_CUSTOM
        if [[ "$NGRAM_CUSTOM" =~ ^[Yy]$ ]]; then
          read -rp "    n-match (lookup length, default 24): " TMP_N
          [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MATCH="$TMP_N"
          read -rp "    n-min (draft min tokens, default 48): " TMP_N
          [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MIN="$TMP_N"
          read -rp "    n-max (draft max tokens, default 64): " TMP_N
          [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MAX="$TMP_N"
        fi
        SPEC_FLAGS="--spec-type ngram-mod --spec-ngram-mod-n-match $NGRAM_N_MATCH --spec-ngram-mod-n-min $NGRAM_N_MIN --spec-ngram-mod-n-max $NGRAM_N_MAX"
        ;;
      3)
        NEW_METHOD="ngram-map-k4v"
        SPEC_FLAGS="--spec-type ngram-map-k4v"
        ;;
      4)
        NEW_METHOD="ngram-map-k"
        SPEC_FLAGS="--spec-type ngram-map-k"
        ;;
      5)
        NEW_METHOD="ngram-simple"
        SPEC_FLAGS="--spec-type ngram-simple"
        ;;
      6|*)
        NEW_METHOD="none"
        SPEC_FLAGS=""
        ;;
    esac
  else
    NEW_MTP="no"
    DEFAULT_SPEC=1
    echo ""
    echo "Speculative decoding method:"
    echo "   1) ngram-mod     — n-gram matching, self-speculative (tunable, best quality)"
    echo "   2) ngram-map-k4v — n-gram keys + 4 m-gram values (fast)"
    echo "   3) ngram-map-k   — n-gram keys only"
    echo "   4) ngram-simple  — simple n-gram lookup"
    echo "   5) none (standard) — disable speculative decoding"

    read -rp "Select method [default: $DEFAULT_SPEC]: " SPEC_CHOICE
    case "${SPEC_CHOICE:-$DEFAULT_SPEC}" in
      1)
        NEW_METHOD="ngram-mod"
        read -rp "  Customize ngram-mod params? [y/N]: " NGRAM_CUSTOM
        if [[ "$NGRAM_CUSTOM" =~ ^[Yy]$ ]]; then
          read -rp "    n-match (lookup length, default 24): " TMP_N
          [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MATCH="$TMP_N"
          read -rp "    n-min (draft min tokens, default 48): " TMP_N
          [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MIN="$TMP_N"
          read -rp "    n-max (draft max tokens, default 64): " TMP_N
          [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MAX="$TMP_N"
        fi
        SPEC_FLAGS="--spec-type ngram-mod --spec-ngram-mod-n-match $NGRAM_N_MATCH --spec-ngram-mod-n-min $NGRAM_N_MIN --spec-ngram-mod-n-max $NGRAM_N_MAX"
        ;;
      2)
        NEW_METHOD="ngram-map-k4v"
        SPEC_FLAGS="--spec-type ngram-map-k4v"
        ;;
      3)
        NEW_METHOD="ngram-map-k"
        SPEC_FLAGS="--spec-type ngram-map-k"
        ;;
      4)
        NEW_METHOD="ngram-simple"
        SPEC_FLAGS="--spec-type ngram-simple"
        ;;
      5|*)
        NEW_METHOD="none"
        SPEC_FLAGS=""
        ;;
    esac
  fi

# ─── Summary & confirm ─────────────────────────────────────────────────────────
  echo ""
  echo "  New model   : $NEW_MODEL"
  echo "  ctx-size    : $NEW_CTX"
  echo "  KV cache    : $NEW_KV (K and V)"
  if [ -n "$SPEC_FLAGS" ]; then
    echo "  Spec decode : $NEW_METHOD  $SPEC_FLAGS"
  else
    echo "  Spec decode : $NEW_METHOD"
  fi
  echo "  GPU         : ${GPU_FLAG:-both (split layers)}"
  echo ""
  read -rp "Apply and restart $SERVICE? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  # ─── Rewrite ExecStart & restart ──────────────────────────────────────────────
  rewrite_execstart "$NEW_MODEL" "$NEW_CTX" "$NEW_KV" "$SPEC_FLAGS" "$GPU_FLAG"

systemctl daemon-reload
systemctl restart "$SERVICE"

# ─── Wait for service to come up ──────────────────────────────────────────────
echo ""
echo "  Waiting for $SERVICE to start..."
for i in {1..15}; do
  if systemctl is-active --quiet "$SERVICE"; then
    break
  fi
  sleep 2
done

if systemctl is-active --quiet "$SERVICE"; then
  echo "  [✓] Switched to : $NEW_MODEL"
  echo "  [✓] ctx-size    : $NEW_CTX"
  echo "  [✓] KV cache    : $NEW_KV (K and V)"
  echo "  [✓] MTP mode    : $NEW_MTP"
  echo "  [✓] Service     : $SERVICE running"
  echo ""
  echo "  Web UI ready at       : http://$(hostname -I | awk '{print $1}'):80"
  echo "  Verify GPU usage with  : amdgpu_top (or vulkaninfo --summary)"
  echo "  Watch logs with       : journalctl -u $SERVICE -f"
else
  echo "  [✗] WARNING: $SERVICE did not start cleanly after switch!"
  echo "  Check logs with: journalctl -u $SERVICE -f"
  exit 1
fi
EOS
chmod +x "$SWITCH_SCRIPT"

# Keep /srv/ai/models/switch-model.sh in sync (both locations exist on this host)
cp "$SWITCH_SCRIPT" "${MODEL_DIR}/switch-model.sh"
chmod +x "${MODEL_DIR}/switch-model.sh"

# --- 6. ENABLE & START SERVICE ---
echo "[6/7] Enabling and starting $SERVICE_NAME..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# --- 7. VERIFICATION ---
echo "[7/7] Verifying setup..."
echo ""
echo "[vulkaninfo summary]"
vulkaninfo --summary | head -20 || echo "vulkaninfo not found or failed"
echo ""
echo "[llama-server version]"
${LLAMA_CPP_DIR}/build/bin/llama-server --version || true
echo ""
echo "[Service status]"
systemctl status "$SERVICE_NAME" --no-pager
echo ""
echo "[Bootstrap complete - v1.2.0]"
echo "  Native llama.cpp web UI : http://<container-ip>:80"
echo "  Switch models with      : switch-model.sh (v1.6.0: MTP + ngram + GPU select)"
echo "  GPU backend             : Vulkan (RADV via Mesa, gfx1150 AMD Radeon 890M)"