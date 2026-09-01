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
- Model switch script (`switch-freetoken-model.sh`)
- Bootstrap script: ROCm 7.14.0 + uv + FreeToken + systemd service on port 1919
- GPU passthrough: 890M iGPU (gfx1150) via cgroup2 rules (same as LXC 101)
- Discovery doc updated: ROCm path confirmed, NVIDIA blocker resolved
