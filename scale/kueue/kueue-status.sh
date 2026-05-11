#!/bin/bash

echo "--- Jobs ---"
oc get job -A -l kueue.x-k8s.io/queue-name

echo ""
echo "--- Workloads ---"
oc get workloads.kueue.x-k8s.io -A -o wide

echo ""
echo "--- Local Queues ---"
oc get localqueue -A -o wide --field-selector metadata.name!=default

echo ""
echo "--- Cluster Queue ---"
oc get clusterqueue -o wide --field-selector metadata.name!=default
