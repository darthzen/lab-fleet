# 01 — Networking: MetalLB + Traefik

    helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace
    kubectl apply -f pools/metallb-pools.yaml

Pool: `192.168.7.150-169` (L2 advertisement). Traefik is the k3s-bundled
chart; `traefik-values.yaml` captures its current config for reference.

The pool manifest lives in `pools/` so Fleet can bundle it separately from the
MetalLB Helm release (it depends on the MetalLB CRDs); see the per-dir
`fleet.yaml` files.
