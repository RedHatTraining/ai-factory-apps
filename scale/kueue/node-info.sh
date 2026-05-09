#!/bin/bash

oc get node -o json | jq '.items[] | {
  node_name: .metadata.name,
  instance_type: .metadata.labels["node.kubernetes.io/instance-type"],
  cpu_capacity: .status.capacity.cpu,
  cpu_allocatable: .status.allocatable.cpu,
  memory_capacity: .status.capacity.memory,
  memory_allocatable: .status.allocatable.memory,
  gpu_capacity: .status.capacity["nvidia.com/gpu"],
  gpu_product: .metadata.labels["nvidia.com/gpu.product"],
  gpu_memory_mb: .metadata.labels["nvidia.com/gpu.memory"],
  gpu_family: .metadata.labels["nvidia.com/gpu.family"],
  gpu_compute_capability: (.metadata.labels["nvidia.com/gpu.compute.major"] + "." + .metadata.labels["nvidia.com/gpu.compute.minor"]),
  cuda_driver: .metadata.labels["nvidia.com/cuda.driver-version.full"],
  cuda_runtime: .metadata.labels["nvidia.com/cuda.runtime-version.full"]
}'
