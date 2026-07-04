# 01 — Networking: MetalLB + Traefik

    helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace
    kubectl apply -f metallb-pools.yaml

Pool: `192.168.7.150-169` (L2 advertisement). Traefik is the k3s-bundled
chart; `traefik-values.yaml` captures its current config for reference.
