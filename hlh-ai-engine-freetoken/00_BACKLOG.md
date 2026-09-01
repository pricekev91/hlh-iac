# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## FreeToken Runtime

- Pin FreeToken version in deploy script (currently uses latest)
- Add `ft checkpoint` support for FTW fast-load model conversion
- Add safetensors model download for FTW conversion pipeline
- Benchmark FreeToken vs llama.cpp on same model (Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf)
- Tune `--ctx-size`, `--batch-size`, and `--parallel` parameters for optimal throughput
- Evaluate `ft bench bw` recommendations for MoE expert offload settings

## Model Management

- Write a FreeToken-specific `switch-model.sh` that also handles FTW conversion
- Add model download helper (`dl.sh`) similar to LXC 101
- Add automatic model selection based on GPU memory (VRAM budget table)
- Add model quality scoring after benchmark runs

## LXC Lifecycle

- Add LXC snapshot before major FreeToken version updates
- Add LXC resource quota enforcement (CPU, memory, I/O)
- Add health check monitoring script (rocm-smi parsing + alerting)

## Ansible Improvements

- Add ansible-lint to CI workflow
- Split configure-freetoken-inside-lxc.sh into multiple Ansible roles
- Add idempotency tests for ansible playbook
- Add ansible-galaxy role packaging for reuse

## OpenTofu

- Add tofu variables for GPU PCI IDs (currently hardcoded via cgroup rules)
- Add tofu output for container IP and API endpoint
- Add tofu state locking for multi-operator safety
- Migrate from telmate/proxmox to bpg/proxmox provider (align with hlh-docker)

## Networking

- Add DNS entry for FreeToken API endpoint
- Add HTTPS/TLS termination on nginx reverse proxy
- Add rate limiting configuration for API endpoints
- Add API key authentication for external consumers

## Observability

- Add Prometheus metrics endpoint for inference latency
- Add structured logging for ft serve
- Add request logging with model name and token count
- Add Grafana dashboard for GPU utilization and throughput

## Deployment

- Add pre-flight checks for GPU availability before deployment
- Add dry-run / plan mode for deploy script
- Add rollback procedure for failed deployments
- Add CI checks for shell scripts (shellcheck)
