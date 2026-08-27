#!/usr/bin/env bash
# configure-ai-engine-inside-lxc.sh
# Version: 1.0.3-egpu
# Description: Bootstrap llama.cpp AI engine on Ubuntu 24.04 LXC with Vulkan passthrough (eGPU variant)
# Target GPU: AMD Ellesmere RX480 (gfx803 POLARIS10) 8GB via OCuLink on Minisforum DG2 / Proxmox 9.x privileged LXC
#             Also exposes iGPU (gfx1150 890M) — both /dev/dri devices visible; selection via --device flag.
#             Discrete VRAM = 8GB (no shared system RAM like APU), so LXC RAM reduced to 2GB.
# Requirements: Run as root inside privileged LXC with GPU passthrough and /srv/ai/models bind mount
# Changelog:
#   1.0.3-egpu - Fork for hlh-ai-engine-egpu-vulkan LXC 130: RX480 Ellesmere 8GB via OCuLink, 2GB LXC RAM
#                Both GPUs visible (/dev/dri), 8GB VRAM caveat documented
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
SWITCH_SCRIPT="/usr/local/bin/vulkan-switch-model.sh"

# --- 1. BASE DEPENDENCIES ---
echo "[1/7] Installing base dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip bc \
  libopenblas-dev libssl-dev ca-certificates gnupg \
  openssh-server \
  libvulkan1 libvulkan-dev mesa-vulkan-drivers vulkan-tools glslc \
  spirv-headers glslang-tools

# Add root to render and video groups for GPU access (both iGPU and eGPU via /dev/dri)
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
# OOM protection: 4GB LXC with -j$(nproc) kills cc1plus (eGPU variant). Cap jobs by RAM.
# ~1.5GB per cc1plus for ggml-vulkan shaders; reserve 1GB for OS.
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
# Approx 1500 MB per job, max 12
AVAIL_MB=$(( TOTAL_MEM_KB / 1024 - 1024 ))
if [ "$AVAIL_MB" -lt 1500 ]; then JOBS=1
elif [ "$AVAIL_MB" -lt 3000 ]; then JOBS=2
elif [ "$AVAIL_MB" -lt 4500 ]; then JOBS=3
else JOBS=$(nproc)
fi
[ "$JOBS" -gt 12 ] && JOBS=12
echo "[2/7] Detected ${TOTAL_MEM_KB}kB RAM -> using -j${JOBS} (was -j$(nproc)) to avoid OOM"
cmake --build build --config Release -j${JOBS}

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
# vulkan-switch-model.sh
# Version: 1.9.0
# Description: Interactive model switcher for llama.cpp ai-engine service (Vulkan backend)
# Supports: model selection, ctx-size, KV cache quantization, speculative decoding (MTP/ngram), GPU selection
# Changelog:
#   1.9.0 - VRAM spillover analysis, CTX size suggestions per GPU, spillover confirmation
#   1.8.1 - Show exact llama-server command being launched
#   1.8.0 - Dynamic Vulkan GPU enumeration from llama.cpp --list-devices
#   1.7.1 - Fixed Vulkan device names (Vulkan0/Vulkan1) for --device flag
#   1.7.0 - Renamed to vulkan-switch-model.sh to distinguish from ROCm variant
#   1.6.1 - Fixed GPU flag: use --device (Vulkan) not --gpu (CUDA/ROCm)
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

# ─── VRAM Estimation Helpers ─────────────────────────────────────────────────────
# Model size estimates (GB) based on param count and quantization
# Format: "model_pattern:size_gb"
declare -A MODEL_SIZE_ESTIMATES=(
  ["0.5b"]="0.3" ["1b"]="0.6" ["1.5b"]="0.9" ["2b"]="1.2" ["2.5b"]="1.5"
  ["3b"]="1.8" ["3.5b"]="2.1" ["4b"]="2.4" ["6b"]="3.6" ["7b"]="4.2"
  ["8b"]="4.8" ["9b"]="5.4" ["12b"]="7.2" ["13b"]="7.8" ["14b"]="8.4"
  ["27b"]="16.2" ["30b"]="18.0" ["32b"]="19.2" ["35b"]="21.0"
  ["70b"]="42.0" ["72b"]="43.2" ["122b"]="73.2"
)

# Quantization multipliers (relative to FP16)
declare -A QUANT_MULTIPLIER=(
  ["q2_k"]="0.25" ["q2_k_m"]="0.25" ["q2_k_s"]="0.25"
  ["q3_k"]="0.31" ["q3_k_m"]="0.31" ["q3_k_s"]="0.31" ["q3_k_l"]="0.31"
  ["q4_0"]="0.38" ["q4_k"]="0.38" ["q4_k_m"]="0.38" ["q4_k_s"]="0.38"
  ["q5_0"]="0.44" ["q5_k"]="0.44" ["q5_k_m"]="0.44" ["q5_k_s"]="0.44"
  ["q6_k"]="0.50" ["q6_0"]="0.50"
  ["q8_0"]="0.63" ["q8_k"]="0.63"
  ["f16"]="1.0" ["f32"]="2.0"
)

# KV cache bytes per token per layer (approx)
# q4_0: ~0.5 bytes/token/layer, q6_0: ~0.75, q8_0: ~1.0
estimate_model_vram_gb() {
  local model_file="$1"
  local basename=$(basename "$model_file" .gguf)
  basename="${basename,,}"  # lowercase

  # Extract param count (e.g., 30b, 35b, 7b, etc.)
  local param_b=0
  if [[ "$basename" =~ ([0-9]+)b ]]; then
    param_b="${BASH_REMATCH[1]}"
  elif [[ "$basename" =~ -([0-9]+)b- ]]; then
    param_b="${BASH_REMATCH[1]}"
  elif [[ "$basename" =~ ([0-9]+)\.([0-9]+)b ]]; then
    param_b="${BASH_REMATCH[1]}"
  fi

  if [ "$param_b" -eq 0 ]; then
    echo "0"
    return
  fi

  # FP16 baseline: 2 bytes per param
  local fp16_gb=$(( param_b * 2 / 1024 * 1000 / 1000 ))  # rough GB
  # Better: param_b * 10^9 * 2 bytes / 1024^3
  fp16_gb=$(echo "scale=2; $param_b * 2 / 1.0737" | bc -l 2>/dev/null || echo "$(( param_b * 2 ))")

  # Extract quantization
  local quant="q4_k_m"
  if [[ "$basename" =~ (q[0-9]_?[a-z]*) ]]; then
    quant="${BASH_REMATCH[1]}"
    quant="${quant,,}"
  fi

  local mult="${QUANT_MULTIPLIER[$quant]:-0.38}"
  local est_gb=$(echo "scale=2; $fp16_gb * $mult" | bc -l 2>/dev/null || echo "$fp16_gb")
  echo "$est_gb"
}

# KV cache estimate in GB: ctx_size * layers * bytes_per_token * 2 (K+V) / 1024^3
# For typical models: ~32-80 layers, ~0.5-1.0 bytes/token/layer depending on quant
estimate_kv_cache_gb() {
  local ctx_size="$1"
  local quant="${2:-q4_0}"
  local layers="${3:-48}"  # default layers to offload

  local bytes_per_token=0
  case "${quant,,}" in
    q2*|q3*) bytes_per_token=0.4 ;;
    q4*)     bytes_per_token=0.5 ;;
    q5*)     bytes_per_token=0.6 ;;
    q6*)     bytes_per_token=0.75 ;;
    q8*)     bytes_per_token=1.0 ;;
    *)       bytes_per_token=0.5 ;;
  esac

  # GB = ctx * layers * bytes * 2 (K+V) / 1024^3
  local kv_gb=$(echo "scale=2; $ctx_size * $layers * $bytes_per_token * 2 / 1073741824" | bc -l 2>/dev/null || echo "0")
  echo "$kv_gb"
}

# Parse GPU VRAM from device info line
parse_gpu_vram_mib() {
  local device_line="$1"
  # "Vulkan0: AMD Radeon RX 480 Graphics (RADV POLARIS10) (8192 MiB, 8186 MiB free)"
  if [[ "$device_line" =~ \(([0-9]+)\ MiB ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "0"
  fi
}

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
echo "║                   vulkan-switch-model.sh                         ║"
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
CUR_GPU=$(grep -- '--device '             "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--device")     print $(i+1)}') || CUR_GPU="both (split)"

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

  # ─── VRAM Analysis (after model selection, before ctx/KV/GPU) ────────────────────
  echo ""
  echo "════════════════════════════════════════════════════════════════════════════════"
  echo "  VRAM ANALYSIS FOR: $(basename "$NEW_MODEL")"
  echo "═══════════════════════════════════════════════════════════════════════════════"

  # Estimate model VRAM
  MODEL_VRAM_GB=$(estimate_model_vram_gb "$NEW_MODEL")
  echo "  Estimated model size: ${MODEL_VRAM_GB} GB (weights only)"

  # We'll do full VRAM analysis after GPU and KV selection
  # For now, show context size recommendations based on typical VRAM
  echo ""
  echo "  Suggested CTX sizes for common GPU VRAM budgets (with q4_0 KV):"
  echo "    GPU VRAM  │  Safe CTX (model+KV < 90% VRAM)  │  Max CTX (model+KV < 100% VRAM)"
  echo "    ──────────┼───────────────────────────────────┼─────────────────────────────────"
  for vram in 8 12 16 24 32 48 64; do
    # Available for KV = VRAM * 0.9 - model
    local kv_budget_90=$(echo "scale=0; $vram * 900 - $MODEL_VRAM_GB * 1000" | bc -l 2>/dev/null || echo "0")
    local kv_budget_100=$(echo "scale=0; $vram * 1000 - $MODEL_VRAM_GB * 1000" | bc -l 2>/dev/null || echo "0")
    # KV per token at q4_0 ~0.5 bytes * 48 layers * 2 / 1024^3 = ~0.000045 GB per token
    local kv_per_token_gb=0.000045
    local safe_ctx=0
    local max_ctx=0
    if [ "$(echo "$kv_budget_90 > 0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
      safe_ctx=$(echo "scale=0; $kv_budget_90 / 1000 / $kv_per_token_gb" | bc -l 2>/dev/null || echo 0)
      max_ctx=$(echo "scale=0; $kv_budget_100 / 1000 / $kv_per_token_gb" | bc -l 2>/dev/null || echo 0)
    fi
    # Round to nearest 1024
    safe_ctx=$(( (safe_ctx / 1024) * 1024 ))
    max_ctx=$(( (max_ctx / 1024) * 1024 ))
    [ "$safe_ctx" -lt 1024 ] && safe_ctx=1024
    [ "$max_ctx" -lt 1024 ] && max_ctx=1024
    printf "    %4d GB   │  %5d tokens (%dK)                    │  %5d tokens (%dK)\n" \
      "$vram" "$safe_ctx" "$((safe_ctx/1024))" "$max_ctx" "$((max_ctx/1024))"
  done
  echo "════════════════════════════════════════════════════════════════════════════════"

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

# ─── GPU selection (dynamic enumeration) ────────────────────────────────────────
  echo ""
  echo "GPU selection (FORCE single GPU — multi-GPU splits layers and tanks tok/s on bandwidth-starved iGPU):"
  
  # Get available Vulkan devices from llama.cpp (format: "  Vulkan0: AMD Radeon RX 480 ...")
  mapfile -t VULKAN_DEVICE_LINES < <(/opt/llama.cpp/build/bin/llama-server --list-devices 2>/dev/null | grep -E '^  Vulkan[0-9]+:')
  
  if [ "${#VULKAN_DEVICE_LINES[@]}" -eq 0 ]; then
    echo "  WARNING: No Vulkan devices detected by llama.cpp"
    echo "  Falling back to CPU-only mode"
    GPU_FLAG=""
  else
    echo "  Available Vulkan devices:"
    for i in "${!VULKAN_DEVICE_LINES[@]}"; do
      # Parse: "  Vulkan0: AMD Radeon RX 480 Graphics (RADV POLARIS10) (8192 MiB, 8186 MiB free)"
      DEVICE_NAME=$(echo "${VULKAN_DEVICE_LINES[$i]}" | sed 's/^  //' | cut -d: -f1)
      DEVICE_INFO=$(echo "${VULKAN_DEVICE_LINES[$i]}" | cut -d: -f2- | sed 's/^ //')
      echo "    $((i+1))) $DEVICE_NAME — $DEVICE_INFO"
    done
    echo "    $(( ${#VULKAN_DEVICE_LINES[@]} + 1 ))) All GPUs — split layers across all (default llama.cpp behavior, SLOW on bandwidth-starved iGPU)"
    echo ""
    read -rp "Select GPU [default: ${#VULKAN_DEVICE_LINES[@]}]: " GPU_CHOICE
    DEFAULT_GPU="${#VULKAN_DEVICE_LINES[@]}"
    case "${GPU_CHOICE:-$DEFAULT_GPU}" in
      *[!0-9]*) GPU_FLAG="--device $(echo "${VULKAN_DEVICE_LINES[0]}" | sed 's/^  //' | cut -d: -f1)" ;;  # fallback
      *)
        if [ "$GPU_CHOICE" -ge 1 ] && [ "$GPU_CHOICE" -le "${#VULKAN_DEVICE_LINES[@]}" ]; then
          SELECTED_DEVICE=$(echo "${VULKAN_DEVICE_LINES[$((GPU_CHOICE-1))]}" | sed 's/^  //' | cut -d: -f1)
          GPU_FLAG="--device $SELECTED_DEVICE"
        elif [ "$GPU_CHOICE" -eq "$(( ${#VULKAN_DEVICE_LINES[@]} + 1 ))" ]; then
          GPU_FLAG=""  # all GPUs
        else
          SELECTED_DEVICE=$(echo "${VULKAN_DEVICE_LINES[$((DEFAULT_GPU-1))]}" | sed 's/^  //' | cut -d: -f1)
          GPU_FLAG="--device $SELECTED_DEVICE"  # fallback to last
        fi
        ;;
    esac
  fi

  # ─── VRAM Spillover Analysis (after GPU/KV/ctx selected) ────────────────────────
  echo ""
  echo "════════════════════════════════════════════════════════════════════════════════"
  echo "  VRAM SPILLOVER ANALYSIS"
  echo "═══════════════════════════════════════════════════════════════════════════════"

  # Get selected GPU VRAM
  SELECTED_GPU_VRAM_MIB=0
  if [ -n "$GPU_FLAG" ] && [[ "$GPU_FLAG" =~ --device\ (.+) ]]; then
    SELECTED_DEVICE="${BASH_REMATCH[1]}"
    for line in "${VULKAN_DEVICE_LINES[@]}"; do
      if [[ "$line" =~ ^\  ${SELECTED_DEVICE}: ]]; then
        SELECTED_GPU_VRAM_MIB=$(parse_gpu_vram_mib "$line")
        break
      fi
    done
  fi

  # Calculate total VRAM needed
  KV_VRAM_GB=$(estimate_kv_cache_gb "$NEW_CTX" "$NEW_KV")
  TOTAL_VRAM_GB=$(echo "scale=2; $MODEL_VRAM_GB + $KV_VRAM_GB" | bc -l 2>/dev/null || echo "0")
  SELECTED_GPU_VRAM_GB=$(echo "scale=2; $SELECTED_GPU_VRAM_MIB / 1024" | bc -l 2>/dev/null || echo "0")

  echo "  Selected GPU VRAM: ${SELECTED_GPU_VRAM_GB} GB"
  echo "  Model weights:     ${MODEL_VRAM_GB} GB"
  echo "  KV cache (${NEW_CTX} ctx, ${NEW_KV}): ${KV_VRAM_GB} GB"
  echo "  ────────────────────────────────────────────"
  echo "  Total VRAM needed: ${TOTAL_VRAM_GB} GB"

  # Check for spillover
  SPILLOVER_GB="0"
  if [ "$(echo "$TOTAL_VRAM_GB > $SELECTED_GPU_VRAM_GB" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
    SPILLOVER_GB=$(echo "scale=2; $TOTAL_VRAM_GB - $SELECTED_GPU_VRAM_GB" | bc -l 2>/dev/null || echo "0")
    echo ""
    echo "  ⚠️  WARNING: VRAM SPILLOVER DETECTED!"
    echo "  ⚠️  ${SPILLOVER_GB} GB will spill to system RAM (slower inference)"
    echo "  ⚠️  llama.cpp will automatically use system RAM when VRAM is exhausted"
    echo ""
    echo "  Options to avoid spillover:"
    echo "    - Reduce context size (current: $NEW_CTX)"
    echo "    - Use lower KV quantization (current: $NEW_KV)"
    echo "    - Select a GPU with more VRAM"
    echo ""
    read -rp "  Continue with spillover? [y/N]: " SPILLOVER_CONFIRM
    if [[ ! "$SPILLOVER_CONFIRM" =~ ^[Yy]$ ]]; then
      echo "  Aborted. Re-run and choose smaller ctx/KV or different GPU."
      exit 0
    fi
  else
    HEADROOM_GB=$(echo "scale=2; $SELECTED_GPU_VRAM_GB - $TOTAL_VRAM_GB" | bc -l 2>/dev/null || echo "0")
    echo "  ✓ Fits in VRAM with ${HEADROOM_GB} GB headroom"
  fi

  echo "════════════════════════════════════════════════════════════════════════════════"

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

  # Show the exact command that will be executed
  echo ""
  echo "  ────────────────────────────────────────────────────────────────────────────"
  echo "  Exact command being launched (from $SYSTEMD_SERVICE):"
  # Extract the full ExecStart block (multi-line with backslash continuations)
  sed -n '/^ExecStart=.*llama-server/,/^Restart=/p' "$SYSTEMD_SERVICE" | head -n -1 | sed 's/^/  /'
  echo "  ────────────────────────────────────────────────────────────────────────────"
  echo ""

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

# Keep /srv/ai/models/vulkan-switch-model.sh in sync (both locations exist on this host)
cp "$SWITCH_SCRIPT" "${MODEL_DIR}/vulkan-switch-model.sh"
chmod +x "${MODEL_DIR}/vulkan-switch-model.sh"

# --- 5b. eGPU helper: pin to RX480 regardless of Vulkan index ---
echo "[5/7] Creating eGPU RX480 helper: /usr/local/bin/egpu-hlh-ai-engine-vulkan.sh + ${MODEL_DIR}/..."
EGPU_HELPER="/usr/local/bin/egpu-hlh-ai-engine-vulkan.sh"
cat > "$EGPU_HELPER" << 'EOS_EGPU'
#!/usr/bin/env bash
# egpu-hlh-ai-engine-vulkan.sh
# Version: 1.0.0-egpu
# Description: Helper to target the RX480 eGPU (Ellesmere/POLARIS10/gfx803 8GB) regardless of Vulkan index
# Usage:
#   egpu-hlh-ai-engine-vulkan.sh              # detect and show RX480 Vulkan device
#   egpu-hlh-ai-engine-vulkan.sh --device-only # print only "--device VulkanX" (for scripting)
#   egpu-hlh-ai-engine-vulkan.sh --apply       # patch ai-engine service to use RX480 and restart
#   egpu-hlh-ai-engine-vulkan.sh --apply --ctx-size 8192 --cache-type-k q4_0  # (future: keep current ctx/kv if not given)
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

# Enumerate via llama.cpp if available, else vulkaninfo
mapfile -t VULKAN_LINES < <($LLAMA_BIN --list-devices 2>/dev/null | grep -E '^  Vulkan[0-9]+:' || true)
if [ "${#VULKAN_LINES[@]}" -eq 0 ]; then
  # fallback via vulkaninfo
  mapfile -t VULKAN_LINES < <(vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|deviceType' | head -20 || true)
  echo "WARNING: llama-server --list-devices returned 0 devices, trying vulkaninfo fallback" >&2
fi

if [ "${#VULKAN_LINES[@]}" -eq 0 ]; then
  echo "ERROR: No Vulkan devices found. Check /dev/dri passthrough and mesa-vulkan-drivers." >&2
  exit 1
fi

echo "Detected Vulkan devices:" >&2
for l in "${VULKAN_LINES[@]}"; do echo "  $l" >&2; done

# Try exact RX480 match
RX_LINE=""
for l in "${VULKAN_LINES[@]}"; do
  if echo "$l" | grep -qiE 'RX ?480|Ellesmere|POLARIS10|gfx803'; then
    RX_LINE="$l"
    break
  fi
done
# Fallback: 8192 MiB (RX480 8GB)
if [ -z "$RX_LINE" ]; then
  for l in "${VULKAN_LINES[@]}"; do
    if echo "$l" | grep -q '8192 MiB'; then
      RX_LINE="$l"
      echo "INFO: No exact RX480 string match, using 8192 MiB fallback -> $l" >&2
      break
    fi
  done
fi
# Fallback: first RADV/AMD line
if [ -z "$RX_LINE" ]; then
  for l in "${VULKAN_LINES[@]}"; do
    if echo "$l" | grep -qiE 'AMD|RADV'; then
      RX_LINE="$l"
      echo "INFO: Using first AMD/RADV fallback -> $l" >&2
      break
    fi
  done
fi
if [ -z "$RX_LINE" ]; then
  RX_LINE="${VULKAN_LINES[0]}"
  echo "WARNING: No AMD match, using first device -> $RX_LINE" >&2
fi

# Extract VulkanX id: "  Vulkan1: ..." -> Vulkan1
RX_DEVICE=$(echo "$RX_LINE" | sed -n 's/^  \(Vulkan[0-9]\+\):.*/\1/p')
if [ -z "$RX_DEVICE" ]; then
  # try vulkaninfo fallback format
  RX_DEVICE="Vulkan0"
  echo "WARNING: Could not parse Vulkan id, defaulting to Vulkan0" >&2
fi

RX_INFO=$(echo "$RX_LINE" | cut -d: -f2- | sed 's/^ //')
echo "" >&2
echo "RX480 target: $RX_DEVICE — $RX_INFO" >&2

if [ "$MODE" == "device-only" ]; then
  echo "--device $RX_DEVICE"
  exit 0
fi
if [ "$MODE" == "show" ]; then
  echo ""
  echo "Use: --device $RX_DEVICE  (e.g. llama-server --device $RX_DEVICE --model ... )"
  echo "To pin ai-engine service: sudo $0 --apply"
  # also show current service pin
  CUR_GPU=$(grep -- '--device ' "$SYSTEMD_SERVICE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="--device") print $(i+1)}' || echo "both (split)")
  echo "Current service GPU: ${CUR_GPU:-both (split)}"
  exit 0
fi

# --apply: patch systemd service ExecStart to use RX480
if [ "$MODE" == "apply" ]; then
  if [ ! -f "$SYSTEMD_SERVICE" ]; then
    echo "ERROR: $SYSTEMD_SERVICE not found" >&2; exit 1
  fi
  # Extract current model/ctx/kv/spec to keep (reuse awk rewrite logic from vulkan-switch-model.sh)
  CUR_MODEL=$(grep -- '--model ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model") print $(i+1)}')
  CUR_CTX=$(grep -- '--ctx-size ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--ctx-size") print $(i+1)}' || echo "4096")
  CUR_KV_K=$(grep -- '--cache-type-k ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--cache-type-k") print $(i+1)}' || echo "q4_0")
  CUR_SPEC=$(grep -- '--spec-type ' "$SYSTEMD_SERVICE" | sed -n 's/.*--spec-type \([^ ]*\).*/\1/p' || true)
  SPEC_FLAGS=""
  if [ -n "$CUR_SPEC" ]; then
    # preserve spec line roughly (simplified: keep current spec-type if present)
    SPEC_FLAGS=$(grep -o -- '--spec-type[^\\]*' "$SYSTEMD_SERVICE" | head -1 | sed 's/ *\\$//' | xargs || true)
  fi
  GPU_FLAG="--device $RX_DEVICE"
  echo "Patching $SYSTEMD_SERVICE to pin $GPU_FLAG (keeping model=$CUR_MODEL ctx=$CUR_CTX kv=$CUR_KV_K)..." >&2

  # Minimal sed-free awk rewrite: replace or inject --device
  tmp=$(mktemp)
  cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"
  awk -v gpu="$GPU_FLAG" '
    BEGIN{in_block=0}
    /^ExecStart=.*llama-server/ {in_block=1; print; next}
    in_block {
      if (/--device /) { sub(/--device [^ \\]*/, gpu); in_block=0; print; next }
      if (/\\$/) { print; next }
      # end of ExecStart block (next is Restart=) -> inject gpu flag before --parallel or at end
      if (/^Restart=/) {
        # inject before Restart if no --device was found yet
        print "  " gpu " \\"
        in_block=0
        print
        next
      }
      print; next
    }
    {print}
  ' "$SYSTEMD_SERVICE" > "$tmp" || { rm -f "$tmp"; echo "ERROR: awk rewrite failed" >&2; exit 1; }
  # If still no --device, ensure it is present (fallback injection before --parallel)
  if ! grep -q -- '--device ' "$tmp"; then
    awk -v gpu="$GPU_FLAG" '{ if (/--parallel 1/) sub(/--parallel 1/, gpu " --parallel 1"); print }' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
  fi
  mv "$tmp" "$SYSTEMD_SERVICE"
  echo "Updated service ExecStart:" >&2
  sed -n '/^ExecStart=.*llama-server/,/^Restart=/p' "$SYSTEMD_SERVICE" | head -n -1 | sed 's/^/  /' >&2
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  for i in {1..15}; do systemctl is-active --quiet "$SERVICE" && break; sleep 2; done
  if systemctl is-active --quiet "$SERVICE"; then
    echo "[✓] ai-engine now pinned to $RX_DEVICE ($RX_INFO)" >&2
    echo "Web UI: http://$(hostname -I | awk '{print $1}'):80" >&2
  else
    echo "[✗] Service failed to start after pinning. Check journalctl -u $SERVICE -f" >&2
    exit 1
  fi
fi
EOS_EGPU
chmod +x "$EGPU_HELPER"
# Copy to shared model storage (visible on host and all LXCs)
cp "$EGPU_HELPER" "${MODEL_DIR}/egpu-hlh-ai-engine-vulkan.sh"
chmod +x "${MODEL_DIR}/egpu-hlh-ai-engine-vulkan.sh"
# Alias for user typo vuklan -> vulkan
cp "$EGPU_HELPER" "${MODEL_DIR}/egpu-hlh-ai-engine-vuklan.sh"
chmod +x "${MODEL_DIR}/egpu-hlh-ai-engine-vuklan.sh"
cp "$EGPU_HELPER" "/usr/local/bin/egpu-hlh-ai-engine-vuklan.sh"
chmod +x "/usr/local/bin/egpu-hlh-ai-engine-vuklan.sh"
ln -sf egpu-hlh-ai-engine-vulkan.sh /usr/local/bin/egpu-rx480.sh 2>/dev/null || true
ln -sf egpu-hlh-ai-engine-vulkan.sh "${MODEL_DIR}/egpu-rx480.sh" 2>/dev/null || true

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
echo "[Bootstrap complete - v1.0.3-egpu]"
echo "  Native llama.cpp web UI : http://<container-ip>:80 (LXC 130 -> 192.168.1.30:80)"
echo "  Switch models with      : vulkan-switch-model.sh (v1.9.0: VRAM spillover analysis + CTX suggestions + exact cmd)"
echo "  GPU backend             : Vulkan (RADV via Mesa, gfx803 Ellesmere RX480 8GB via OCuLink; iGPU gfx1150 also visible)"
echo "  NOTE: eGPU has 8GB dedicated VRAM — large 30B models will spill to RAM. Use 8-16K ctx + q4_0."