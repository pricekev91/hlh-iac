# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Upgrade ROCm from 7.2.3 to 7.14.0 (native gfx1150 rocBLAS support)
- Switch llama-server from port 8080 (nginx) to port 80 (native web UI)
- Update default model to Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

### Fixed

- Fix ROCm 7.14 repo URLs for Ubuntu 24.04
- Install ROCm dev package required for HIP CMake builds

## [0.3.1] - 2026-06

### Fixed

- Flatten repository layout to repo root (d187300)

## [0.3.0] - 2026-05

### Changed

- Prefer Q4_K_M ai-engine model on bootstrap (46bc607)

### Fixed

- Revert ai-engine GPU layer selection change (03777d7)

## [0.2.1] - 2026-05

### Added

- Partial GPU offload control for large ai-engine models (5b6b91c)

### Fixed

- Fix switch-model awk quoting for port 80 rewrite (60cd89e)

## [0.2.0] - 2026-04

### Changed

- Move ai-engine webui to port 80 and remove turboquant option (5c53144)
- Rename ai-engine LXC hostname to hlh-ai-engine (9db702b)
- Rename ai-engine provision script to deploy (56b615f)

### Added

- switch-model.sh v1.3.0 with MTP auto-detect (f4da34f)
- Working llama.cpp ROCm 7.2.3 deployment on gfx1150 (890M) (547768a)

### Fixed

- Pin LXC 101 to static 192.168.1.12 (fd72026)
- Skip default model download when mount already has gguf (f1ff9df)
- Mount /srv/ai/models host path into LXC (f2c49ca)

## [0.1.0] - 2026-04

### Added

- Initial AI engine LXC deployment scaffolding
- ROCm 7.2.3 installation via amdgpu-install
- Ansible playbook for in-container configuration
- OpenTofu module for Proxmox LXC provisioning
- deploy-hlh-ai-engine.sh: LXC creation, GPU passthrough, bootstrap
- Configure-hlh-ai-engine.sh: in-container configuration

### Fixed

- ZFS rootfs creation syntax for Proxmox 9.x (multiple fixes across 20+ commits)
