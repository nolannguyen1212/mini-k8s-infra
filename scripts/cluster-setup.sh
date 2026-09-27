#!/bin/sh

. "$(dirname "$0")/common.sh"

set -x

CLUSTER=lab
KIND_CONFIG="$(dirname "$0")/../config/kind/kind-config.yaml"

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG"
fi

sh "$(dirname "$0")/ingress-setup.sh"
sh "$(dirname "$0")/vault-setup.sh"