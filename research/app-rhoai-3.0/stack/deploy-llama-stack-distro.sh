#!/usr/bin/env bash

export INFERENCE_MODEL="llama-32-3b-instruct"
export VLLM_URL="http://llama-32-3b-instruct-predictor.my-first-model.svc.cluster.local:8080/v1"
export VLLM_TLS_VERIFY="false"   # Use "true" in production
export VLLM_API_TOKEN=""

oc create secret generic llama-stack-inference-model-secret \
  --from-literal=INFERENCE_MODEL="$INFERENCE_MODEL" \
  --from-literal=VLLM_URL="$VLLM_URL" \
  --from-literal=VLLM_TLS_VERIFY="$VLLM_TLS_VERIFY" \
  --from-literal=VLLM_API_TOKEN="$VLLM_API_TOKEN"

oc apply -f llama-stack-distro.yaml


