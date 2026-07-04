# 11 — Emby (home media server)

    kubectl apply -f emby.yaml

Hardware transcoding: the deployment pins the second GPU by UUID with
`NVIDIA_DRIVER_CAPABILITIES=compute,utility,video`. Media libraries mount from
host/NFS paths; see the volumes block in the manifest.
