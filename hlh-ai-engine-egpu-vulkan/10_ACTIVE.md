# TODO

Active items in progress. These are the current focus areas.

## Active

- [ ] Validate Vulkan (RADV) GPU passthrough on LXC 130 (RX480 Ellesmere 8GB via OCuLink) with both GPUs visible
- [ ] Verify 8GB LXC RAM is sufficient for llama.cpp Vulkan build (was 2GB→4GB OOM, bumped to 8GB)
- [ ] Confirm final DNS hostnames for eGPU AI endpoint (192.168.1.30)
- [ ] Compare eGPU RX480 vs iGPU 890M inference performance (Vulkan)

## This Week

- [ ] Run deploy-hlh-ai-engine-egpu-vulkan.sh on prox01 to verify LXC 130 creation flow (full cycle)
- [ ] Test model switching after LXC bootstrap (vulkan-switch-model.sh — verify both Vulkan devices enumerated)
- [ ] Validate Mesa RADV driver compatibility for gfx803 Polaris10 on latest amdgpu kernel
- [ ] Test spillover behavior with 30B Q4_K_M on 8GB VRAM (expect RAM spill)
