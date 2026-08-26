# ModelCar OCI Image: Qwen3-4B FP8

Build an OCI model image from the FP8-quantized model stored on a PVC in OpenShift.

## Prerequisites

- The `quantize-model` job has completed and the quantized model exists on the `quantize-workspace` PVC at `/workspace/qwen3-4b-fp8`.
- You have `oc` access to the `prepare-quantize` namespace.
- `podman` is installed on your workstation.
- You have push access to `quay.io/redhattraining`.

## 1. Copy the quantized model from the PVC

Create a helper pod that mounts the PVC:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: copy-model
  namespace: prepare-quantize
spec:
  containers:
  - name: sleep
    image: registry.access.redhat.com/ubi9/ubi:latest
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: workspace
      mountPath: /workspace
  volumes:
  - name: workspace
    persistentVolumeClaim:
      claimName: quantize-workspace
EOF

oc wait --for=condition=Ready pod/copy-model -n prepare-quantize --timeout=120s
```

Copy the model files to your workstation:

```bash
oc cp prepare-quantize/copy-model:/workspace/qwen3-4b-fp8 model/
```

Clean up the helper pod:

```bash
oc delete pod copy-model -n prepare-quantize
```

## 2. Build and push the OCI image

Build the image using the provided `Containerfile`:

```bash
podman build -t quay.io/redhattraining/modelcar-qwen3-4b:fp8 .
podman push quay.io/redhattraining/modelcar-qwen3-4b:fp8
```

Remember to make the `quay.io/redhattraining/modelcar-qwen3-4b:fp8` repo public.

## 3. Verify

```bash
podman inspect quay.io/redhattraining/modelcar-qwen3-4b:fp8
```
