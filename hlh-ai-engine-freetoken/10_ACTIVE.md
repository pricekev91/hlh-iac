# ACTIVE

Items currently in progress.

## LXC 140 — Initial Deployment

- [x] Scaffold project structure (follows hlh-ai-engine pattern)
- [x] Write OpenTofu module (main.tf, variables.tf)
- [x] Write Ansible inventory + playbook
- [x] Write bootstrap script (configure-freetoken-inside-lxc.sh)
- [x] Write deploy script (nuke & redeploy)
- [x] Write configure script (Ansible wrapper)
- [x] Write support files (README, BACKLOG, CHANGELOG)
- [x] FIX: Corrected IP to 192.168.1.40 (was incorrectly .13)
- [x] FIX: Added hard safety guards to prevent wrong-LXC deployment
- [ ] Deploy to prox01 LXC 140 (IP 192.168.1.40)
- [ ] Verify FreeToken service running on port 1919
- [ ] Run benchmark: FreeToken vs llama.cpp on Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf

## Pending GPU Verification

- [ ] Confirm ROCm 7.14.0 + 890M iGPU works with FreeToken on LXC 140
- [ ] Validate MoE expert offload behavior under `--gpu auto`
- [ ] Check `ft bench bw` output for optimization recommendations
