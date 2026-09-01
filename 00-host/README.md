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
4. Uplink NIC tuning — Wake-on-LAN and the Tailscale UDP GRO settings:

       install -m 0755 uplink-tune /usr/local/sbin/uplink-tune
       install -m 0644 wol-arm.service tailscale-gro.service /etc/systemd/system/
       systemctl daemon-reload
       systemctl enable --now wol-arm.service tailscale-gro.service

   Both units call `uplink-tune`, which resolves the interface carrying the
   IPv4 default route at run time instead of hardcoding a name. NIC names on
   this box are not stable: the 2026-08-29 motherboard swap renamed the uplink
   `enp5s0` -> `enp6s0`, and moving GPUs between PCIe slots renumbers the bus
   and can rename them again.

   The predecessor `wol-enp5s0.service` shows why this matters. It had been
   failing every boot since the board swap with `netlink error: No such
   device`, leaving systemd degraded, and nobody noticed — Wake-on-LAN still
   worked, but only because the `igb` driver defaults to `wol g`. Remote
   power-on was one driver default away from being silently gone.

   Verify with `ethtool <iface> | grep Wake-on` (expect `g`) and
   `ethtool -k <iface> | grep -E 'rx-gro-list|rx-udp-gro-forwarding'`
   (expect `off` and `on`).
