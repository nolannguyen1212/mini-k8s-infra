#!/bin/sh

. "$(dirname "$0")/common.sh"

set -e
set -x

# Install Kind (skip if already installed)
brew install kind

# Create a local Kubernetes cluster
if ! kind get clusters | grep -qx "k8s-deploy"; then
  kind create cluster --name k8s-deploy
fi

# Verify the control plane is reachable
kubectl cluster-info

# Optional: dump cluster state for debugging
# kubectl cluster-info dump

# Explore available Kubernetes API resources
(
  kubectl api-resources | head -n 1
  kubectl api-resources | grep -E '^(deployments|replicasets|services|nodes)'
)

# Learn the Deployment API
kubectl explain deployment

# Inspect the Deployment spec schema
kubectl explain deployment.spec

# Verify cluster nodes
kubectl get nodes -o wide

# Verify namespaces
kubectl get namespaces

# Verify system pods
kubectl get pods -A