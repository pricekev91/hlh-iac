# iac-hlh

`iac-hlh` is now the HLH orchestrator repository.

It coordinates independently versioned infrastructure components instead of carrying their implementation directly in the monorepo.

## Orchestrator Model

The orchestrator owns top-level coordination, bootstrap flow, and pinned component selection.

Component repositories are versioned independently:

- [`hlh-ai-engine`](https://github.com/pricekev91/hlh-ai-engine) — ROCm 890M, LXC 101 (192.168.1.12) — standalone repo
- [`hlh-ai-engine-k80`](https://github.com/pricekev91/hlh-ai-engine-k80) — CUDA K80 dual GK210, LXC 131 (192.168.1.31) — standalone repo (formerly `hlh-ai-engine-egpu-k80`)
- `hlh-docker`

These components were split out of this monorepo on 2026-09-10 with full history preserved via `git filter-repo`. See their standalone repos for deployment (`deploy-*.sh`, `configure-*.sh`, `opentofu/`, `ansible/`).

The repository uses a flat top-level structure for clarity and scalability. Remaining components live at the repo root.

## Deployment Model

`deploy.sh` performs the orchestrator flow:

1. Initialize submodules at the pinned revisions recorded in this repository (if any).
2. Run host bootstrap.
3. Deploy `hlh-ai-engine` (now via `git@github.com:pricekev91/hlh-ai-engine.git`).
4. Deploy `hlh-docker`.

Because component repos are now standalone, deployments consume deterministic component versions by cloning/checking out pinned commits from those repos rather than whatever happens to be latest upstream.