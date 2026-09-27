#!/bin/sh

. "$(dirname "$0")/common.sh"

set -x

VAULT_NS=vault

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

kubectl create namespace "$VAULT_NS" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install vault hashicorp/vault -n "$VAULT_NS" \
  --set "server.dev.enabled=true" \
  --set "injector.enabled=true"

kubectl wait --for=condition=Ready pod/vault-0 -n "$VAULT_NS" --timeout=180s
kubectl rollout status deployment/vault-agent-injector -n "$VAULT_NS" --timeout=120s

kubectl exec -n "$VAULT_NS" vault-0 -- vault status
kubectl exec -n "$VAULT_NS" vault-0 -- vault auth enable kubernetes
kubectl exec -n "$VAULT_NS" vault-0 -- sh -c \
  'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"'

log_success "vault installed, kubernetes auth enabled"