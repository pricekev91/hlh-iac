# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- DFlash2 speculative decoding support (build-time): llama.cpp commit `5ecbe1a`
  (PR #27342, now unmerged/open upstream) and
  switch-model.sh v1.6.1 with DFlash2 draft pairing (`--spec-type draft-dflash`) and
  real readiness check (`/health` probe, crash-loop detection)
- Required-model enforcement: DFlash2 draft GGUF
  `Qwen3.8-27B-DFlash2-Q4_K_M.gguf` is downloaded from
  `z-lab/Qwen3.8-27B-DFlash2-GGUF` if missing (note: no Q2_K variant exists upstream;
  a truncated Q2_K file caused `expected 81, got 58` load failures)
- `dl.sh` resumable HuggingFace downloader written to model dir

### Changed

- llama.cpp build unpinned: tracks latest upstream master again (deterministic
  pin removed at user request; pin recipe kept as comments in the configure
  script). NOTE: DFlash2 PR #27342 is still open upstream, so DFlash2 draft
  support is lost on the next deploy unless the pin is restored
- Upgrade ROCm from 7.2.3 to 7.14.0 (native gfx1150 rocBLAS support)
- Switch llama-server from port 8080 (nginx) to port 80 (native web UI)
- Update default model to Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

### Fixed

- Fix ROCm 7.14 repo URLs for Ubuntu 24.04
- Install ROCm dev package required for HIP CMake builds

### Known limitations

- Qwen3.8-27B decodes at ~4.3 tok/s regardless of speculation method (MTP/DFlash2/none)
  because its Gated Delta Net attention fused kernels are not supported on HIP
  (`fused Gated Delta Net not supported, set to disabled`); Qwen3.6-27B+MTP remains
  the fastest config on this iGPU (~7.6-7.8 tok/s)

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
