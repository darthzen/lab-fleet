# 07 — ComfyUI + filebrowser

    kubectl apply -f comfyui.yaml

`mmartial/comfyui-nvidia-docker` with a Longhorn-backed basedir. GPU access is
by `runtimeClassName: nvidia` plus an explicit `NVIDIA_VISIBLE_DEVICES` UUID —
**not** a device-plugin `nvidia.com/gpu` request, which would let the plugin pick
whichever GPU it liked and override the pin.

**Declared at `replicas: 0`, matching the cluster.** The UUID pinned here is the
Tesla V100 — the same GPU Ollama holds with `OLLAMA_KEEP_ALIVE=-1`
(`04-ollama/values.yaml`), so the two cannot both be resident. Scale to 1 by
editing `comfyui.yaml`, not with `kubectl scale`: once Fleet owns this path it
will reconcile a hand-scaled Deployment straight back to 0.

The filebrowser deployment shares the basedir PVC for model/workflow management;
its own config is on a small PVC (`comfyui-filebrowser-config`) rather than an
emptyDir, because `filebrowser.db` holds the auth state. `glm-model-pvc` holds
large model files.

`comfyui-user-script.yaml.txt` is **reference only, not applied** — a pip
dep-persistence hook that was committed but never reached the cluster. Apply and
verify it by hand before folding it back into `comfyui.yaml`.
