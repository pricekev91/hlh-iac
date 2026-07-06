# Operations

## Deploy

Run from local workstation:

PROXMOX_SSH=root@prox01 ./deploy-hlh-ai-engine-dev.sh

## Verify after deploy

On prox01:

pct status 110
pct exec 110 -- verify-rocm-vllm

## Privileged fallback

If unprivileged mode cannot access /dev/kfd or /dev/dri due to idmap/permission constraints:

1. Stop CT:
   pct stop 110
2. Set privileged mode:
   pct set 110 --unprivileged 0
3. Start CT:
   pct start 110
4. Re-run verifier:
   pct exec 110 -- verify-rocm-vllm

## Re-run in-container install

If ROCm repo compatibility changes:

pct push 110 /root/in-ct-install-rocm-vllm.sh /root/in-ct-install-rocm-vllm.sh
pct exec 110 -- bash -lc "ROCM_APT_CODENAME=noble /root/in-ct-install-rocm-vllm.sh"

## ROCm codename handling

The script uses ROCM_APT_CODENAME=noble by default because vendor repos can lag brand-new Ubuntu releases.
If ROCm publishes native 26.04 repo support, set ROCM_APT_CODENAME to that codename and redeploy.
