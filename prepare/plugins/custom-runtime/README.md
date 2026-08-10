# Custom vLLM Runtime with Qwen3 Plugin

A custom vLLM serving runtime image that includes the `custom-qwen3-plugin`
pip package. The plugin registers `CustomQwen3ForCausalLM` as a supported
architecture in the vLLM model registry, allowing vLLM to load models that
declare this custom architecture.

Based on `registry.redhat.io/rhaii/vllm-cuda-rhel9:3.4.0`.

## Prerequisites

- Authenticated to `registry.redhat.io` (the base image requires a Red Hat pull secret):

  ```bash
  podman login registry.redhat.io
  ```

- Authenticated to `quay.io/redhattraining`:

  ```bash
  podman login quay.io
  ```

## Build and push

```bash
podman build \
  -t quay.io/redhattraining/vllm-custom-qwen3:3.4.0 \
  plugins/custom-runtime/

podman push quay.io/redhattraining/vllm-custom-qwen3:3.4.0
```

## Verify

```bash
podman run --rm --entrypoint pip \
  quay.io/redhattraining/vllm-custom-qwen3:3.4.0 \
  show custom-qwen3-plugin
```

Expected output includes:

```
Name: custom-qwen3-plugin
Version: 0.1.0
```
