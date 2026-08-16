# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## GPU / Vulkan

- Add GPU memory utilization monitoring script (`vulkaninfo`/`amdgpu_top` parsing + alerting)
- Add automatic model eviction when GPU memory is low
- Support multi-GPU workloads (future hardware upgrade)
- Track Mesa/RADV version compatibility matrix across Proxmox kernel updates

## Model Management

- Add model versioning system (pin specific GGUF files per deployment)
- Add model download progress tracking and resume support
- Add model quality scoring after inference testing

## LXC Lifecycle

- Add LXC snapshot before major model updates
- Add LXC resource quota enforcement (CPU, memory, I/O)
- Add LXC snapshot restore procedure

## Ansible Improvements

- Add ansible-lint to CI workflow
- Split configure-ai-engine-inside-lxc.sh into multiple Ansible roles
- Add idempotency tests for ansible playbook
- Add ansible-galaxy role packaging for reuse

## OpenTofu

- Add tofu variables for GPU PCI IDs (currently hardcoded via cgroup rules)
- Add tofu output for container IP and API endpoint
- Add tofu state locking for multi-operator safety
- Migrate from telmate/proxmox to bpg/proxmox provider (align with hlh-docker)

## Networking

- Add DNS entry for engine API endpoint
- Add HTTPS/TLS termination on nginx reverse proxy
- Add rate limiting configuration for API endpoints
- Add API key authentication for external consumers

## Observability

- Add Prometheus metrics endpoint for inference latency
- Add structured logging for llama-server
- Add request logging with model name and token count

## Deployment

- Add pre-flight checks for GPU availability before deployment
- Add dry-run / plan mode for deploy script
- Add rollback procedure for failed deployments
- Add CI checks for shell scripts (shellcheck)
