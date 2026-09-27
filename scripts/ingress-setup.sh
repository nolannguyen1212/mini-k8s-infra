#!/bin/sh

. "$(dirname "$0")/common.sh"

set -x

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
kubectl rollout status -n ingress-nginx deploy/ingress-nginx-controller --timeout=180s

log_success "ingress-nginx ready"