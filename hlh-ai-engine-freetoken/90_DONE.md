# DONE

Completed items.

## v0.2.0 — Open WebUI Integration

- [x] Added Open WebUI from GitHub to LXC 140
- [x] Configured Open WebUI on port 80 (OpenAI API on 1919)
- [x] Built-in authentication enabled (`WEBUI_AUTH=True`)
- [x] Dual systemd services: freetoken (1919) + openwebui (80)
- [x] Open WebUI service depends on FreeToken service
- [x] Bootstrap script: 10 steps (ROCm + uv + FreeToken + Node.js + Open WebUI build)
- [x] Updated deploy script output for both services
- [x] Updated README with runtime contract
- [x] Updated CHANGELOG

## v0.1.2 — Safety & Dependency Fixes

- [x] FIX: CRITICAL IP correction 192.168.1.13 → 192.168.1.40 (all files)
- [x] FIX: Added hard safety guards (dangerous LXC ID rejection)
- [x] FIX: Added gnupg to base apt dependencies
- [x] Updated deploy script output messages

## v0.1.0 — Initial IAC Scaffold

- [x] Project structure created following `hlh-ai-engine` pattern
- [x] OpenTofu module: LXC 140 config (prox01, 192.168.1.40, ROCm GPU passthrough)
- [x] Ansible playbook for FreeToken bootstrap (ROCm + uv + Python)
- [x] Deploy script with nuke & redeploy capability
- [x] Configure script: Ansible-based reconfiguration
- [x] Model switch script: `switch-freetoken-model.sh`
- [x] Bootstrap script: ROCm 7.14.0 + uv + FreeToken + systemd service
- [x] GPU passthrough: 890M iGPU (gfx1150) via cgroup2 rules
- [x] Discovery doc updated: ROCm path confirmed, NVIDIA blocker resolved
