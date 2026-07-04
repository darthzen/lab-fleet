# 02 — Storage: Longhorn 1.12

Installed with default chart values (`values.yaml` is intentionally empty):

    helm upgrade --install longhorn longhorn/longhorn -n longhorn-system --create-namespace

Runtime settings live in the dump (`longhorn/settings.longhorn.io.yaml`).
See `docs/troubleshooting-longhorn-502.md` for the web-UI 502 root cause and fix.
