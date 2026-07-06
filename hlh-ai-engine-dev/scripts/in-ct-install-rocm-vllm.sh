#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
ROCM_APT_CODENAME="${ROCM_APT_CODENAME:-noble}"

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  pciutils \
  python3 \
  python3-venv \
  python3-pip \
  build-essential \
  git

# ROCm userspace in LXC requires no DKMS because kernel drivers remain on host.
BASE_URL="https://repo.radeon.com/amdgpu-install/latest/ubuntu/${ROCM_APT_CODENAME}"
DEB_NAME="$(curl -fsSL "${BASE_URL}/" | grep -Eo 'amdgpu-install_[^"]+_all.deb' | head -n 1 || true)"
if test -z "${DEB_NAME}"; then
  echo "Failed to find amdgpu-install package in ${BASE_URL}."
  echo "Set ROCM_APT_CODENAME to a supported Ubuntu codename and rerun."
  exit 1
fi

curl -fsSL "${BASE_URL}/${DEB_NAME}" -o /tmp/amdgpu-install.deb
apt-get install -y /tmp/amdgpu-install.deb

amdgpu-install -y --usecase=rocm,hip --no-dkms || {
  echo "amdgpu-install failed. Check host device passthrough and ROCm repo compatibility."
  exit 1
}

# Prefer amd-smi, keep rocm-smi as fallback.
apt-get install -y amd-smi || true
apt-get install -y rocm-smi || true

python3 -m venv /opt/vllm-venv
/opt/vllm-venv/bin/pip install --upgrade pip setuptools wheel

# Try ROCm wheel indexes first, then fallback to default index.
/opt/vllm-venv/bin/pip install --upgrade \
  --index-url https://download.pytorch.org/whl/rocm6.4 \
  torch torchvision torchaudio || true

/opt/vllm-venv/bin/pip install --upgrade vllm

cat >/usr/local/bin/vllm-serve <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MODEL="${1:-Qwen/Qwen3-8B}"
exec /opt/vllm-venv/bin/python -m vllm.entrypoints.openai.api_server \
  --host 0.0.0.0 \
  --port 8000 \
  --model "${MODEL}" \
  --gpu-memory-utilization 0.85
EOF
chmod +x /usr/local/bin/vllm-serve

cat >/usr/local/bin/verify-rocm-vllm <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "=== PCI ==="
lspci | grep -Ei 'vga|display|3d|amd' || true

echo "=== /dev passthrough ==="
ls -l /dev/dri || true
ls -l /dev/kfd || true

echo "=== ROCm info ==="
rocminfo | head -n 60 || true

echo "=== AMD SMI ==="
amd-smi static || true
rocm-smi || true

echo "=== Torch HIP availability ==="
/opt/vllm-venv/bin/python - <<'PY'
import torch
print('torch:', torch.__version__)
print('cuda_available:', torch.cuda.is_available())
print('device_count:', torch.cuda.device_count())
if torch.cuda.is_available():
    print('device_name_0:', torch.cuda.get_device_name(0))
PY

echo "=== vLLM version ==="
/opt/vllm-venv/bin/python - <<'PY'
import vllm
print(vllm.__version__)
PY
EOF
chmod +x /usr/local/bin/verify-rocm-vllm

echo "Install complete. Run: verify-rocm-vllm"
