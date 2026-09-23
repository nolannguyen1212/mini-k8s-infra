#!/bin/sh

. "$(dirname "$0")/common.sh"

set -e
set -x

CLUSTER=lab
KIND_CONFIG="$(dirname "$0")/k8s/kind-config.yaml"

# Install kind (skip if already installed)
command -v kind >/dev/null || brew install kind

# Create cluster with port mappings and ingress-ready label
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG"
fi

# Fail fast if the cluster was created without port 80 mapping
docker ps --filter "name=^${CLUSTER}-control-plane$" --format '{{.Ports}}' \
  | grep -q '0.0.0.0:80->80/tcp' || {
    echo "Cluster '$CLUSTER' has no port 80 mapping."
    echo "Recreate it: kind delete cluster --name $CLUSTER"
    exit 1
  }

kubectl cluster-info
kubectl get nodes -o wide

# Install ingress controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
kubectl rollout status -n ingress-nginx deploy/ingress-nginx-controller --timeout=180s