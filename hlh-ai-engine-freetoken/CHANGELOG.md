# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- IAC scaffold for FreeToken AI engine (LXC 140)
- OpenTofu module for LXC 140 provisioning
- Ansible playbook for FreeToken bootstrap (ROCm + uv + Python)
- Deploy script with nuke & redeploy capability
- Configure script: Ansible-based reconfiguration
- Model switch script (`switch-freetoken-model.sh`)
- Bootstrap script: ROCm 7.14.0 + uv + FreeToken + systemd service
- GPU passthrough: 890M iGPU (gfx1150) via cgroup2 rules
- Discovery doc updated: ROCm path confirmed, NVIDIA blocker resolved

### Fixed
- **CRITICAL FIX**: Corrected IP from 192.168.1.13 to 192.168.1.40 (CT140 → .40)
- **SAFETY**: Added hard guardrails to deploy script:
  - Explicit LXC_ID=140 with dangerous ID rejection (101, 130, 102, 120)
  - Directory name verification to prevent running wrong script
  - Clear confirmation prompt before any LXC destruction
- All IP references updated across all files (README, deploy, inventory, tofu)
- Added gnupg to base dependencies for ROCm repo key import

## [0.2.0] - Open WebUI Integration

### Added
- Open WebUI installed from GitHub on port 80
- Open WebUI configured to connect to FreeToken on localhost:1919
- Built-in authentication enabled for Open WebUI (`WEBUI_AUTH=True`)
- Dual systemd services: `freetoken.service` (1919) + `openwebui.service` (80)
- Open WebUI service depends on FreeToken service
- Updated bootstrap script to build Open WebUI from source (Node.js)
- Updated deploy script output to show both services
- Updated README with runtime contract for both services

### Changed
- Bootstrap script step count: 8/8 → 10/10 (added Node.js + Open WebUI build steps)
- Deploy script output: updated to show Open WebUI endpoint on port 80
- Open WebUI uses `main.py` directly (not Docker) as per user requirements
