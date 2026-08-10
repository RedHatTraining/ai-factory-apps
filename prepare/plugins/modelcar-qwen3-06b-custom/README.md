# ModelCar OCI Image: Qwen3-0.6B with Custom Architecture

A copy of `modelcar-qwen3-06b:v1` with `config.json` modified to declare
`"architectures": ["CustomQwen3ForCausalLM"]` instead of `["Qwen3ForCausalLM"]`.

Used in the vLLM plugins exercise to demonstrate that vLLM rejects unknown
model architectures and that a custom plugin can register support for them.

## Build and push

```bash
podman build -t quay.io/redhattraining/modelcar-qwen3-06b-custom:v1 .
podman push quay.io/redhattraining/modelcar-qwen3-06b-custom:v1
```

## Verify

```bash
podman run --rm quay.io/redhattraining/modelcar-qwen3-06b-custom:v1 \
  cat /models/config.json | python3 -c "import json,sys; print(json.load(sys.stdin)['architectures'])"
```

Expected output: `['CustomQwen3ForCausalLM']`
