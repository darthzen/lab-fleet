# 07 — ComfyUI + filebrowser

    kubectl apply -f comfyui.yaml

`mmartial/comfyui-nvidia-docker` with a Longhorn-backed basedir; requests one
GPU via the device plugin. The filebrowser deployment shares the PVC for
model/workflow management. `glm-model-pvc` holds large model files.
