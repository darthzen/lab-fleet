# 00 — Host Preparation (openSUSE Leap 16.0)

1. NVIDIA proprietary driver, G06 flavor (V100 needs proprietary; the open
   G07 driver does not support Volta):

       zypper addrepo https://download.nvidia.com/opensuse/leap/16.0/ NVIDIA
       zypper install nvidia-video-G06 nvidia-compute-utils-G06

   Blacklist nouveau, verify with `nvidia-smi -L`, enable persistence mode.
2. NVIDIA container toolkit + CDI spec:

       zypper ar https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
       zypper install nvidia-container-toolkit
       nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

3. k3s (standard install; traefik + servicelb defaults kept, servicelb replaced
   by MetalLB — install k3s with `--disable servicelb`). Restart k3s after the
   container toolkit so containerd regenerates config with the nvidia runtime.
