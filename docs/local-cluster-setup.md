# Local development cluster (kind)

- Runs on a local `kind` cluster for the whole docs set
- Not a disposable exercise environment: this is where the actual repo gets built and iterated on fastest

## What kind actually is

kind (Kubernetes IN Docker) runs each cluster "node" as a Docker container, with Kubernetes installed inside it. One control-plane container is enough for everything here. It is not a lightweight VM and not minikube, it is genuinely upstream Kubernetes, just packaged to boot in seconds on your laptop using Docker as the substrate instead of a VM or bare metal.

**Why kind over minikube:** minikube runs the cluster inside a VM (or a single Docker container in driver=docker mode) and ships its own wrapper CLI, addon system, and mostly-single-node model: more moving parts, more magic hidden from you. kind is just Docker containers plus stock upstream Kubernetes, so `kubectl` behaves exactly like it would against any real cluster, multi-node configs are one YAML file away, and cluster boot/teardown is fast enough to do many times a day. Neither is "more real" than the other for API purposes, but kind's lower ceremony is why it's used here and why it's the more common choice in CI pipelines: a transferable skill, not a toy.

## scripts/cluster-setup.sh, and what it actually does

Everything from [GitOps and the repo layout](gitops-repo-layout.md) onward is a file inside this same repo (`k8s/`, `charts/`, `apps/` at the root, no separate repo to `git init`). Cluster bootstrap lives in `scripts/`, one file per platform dependency (`cluster-setup.sh`, `ingress-setup.sh`, `vault-setup.sh`, plus `common.sh` for shared logging) instead of one long script: walk through what they do once, rather than typing the same commands by hand. `make cluster` runs the whole chain.

`scripts/cluster-setup.sh`:

```sh
. "$(dirname "$0")/common.sh"
```
Sources shared logging helpers (`log_info`, `log_success`, etc) and a colorized `PS4` for `set -x` tracing, into **this same shell process**. This has to be `.` (source), not `sh common.sh`: `sh` would run `common.sh` as its own child process, define those functions/vars inside it, then throw all of it away the instant that child exits, leaving `cluster-setup.sh` with none of them. Never execute `common.sh` directly either (`./common.sh`), same reason: it defines things for the calling shell, it does nothing on its own.

```sh
set -x
```
`-x` echoes every command before running it. No `-e` here on purpose: [scripts/vault-setup.sh](vault-secrets.md#install-vault-dev-mode) calls `vault auth enable kubernetes`, which errors on every run after the first (the auth method is already enabled). `-e` would abort this whole chain the second time you run `make cluster` against a cluster that already has Vault on it. Dropping `-e` trades "fail loudly on the first error" for "safe to re-run from scratch or against an existing cluster," accepting that one expected, non-fatal error prints on every re-run.

```sh
CLUSTER=lab
KIND_CONFIG="$(dirname "$0")/../config/kind/kind-config.yaml"
```
The cluster is named `lab` throughout this repo's scripts: not the name of anything being deployed, just this local sandbox's own identity. `kind-config.yaml` lives at `config/kind/kind-config.yaml` (see [Cluster config for later chapters](#cluster-config-for-later-chapters)), not `k8s/`: it configures the `kind` CLI itself, it's never applied to any apiserver, so it doesn't belong next to the real Kubernetes objects in `k8s/`.

```sh
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG"
fi
```
Checks whether a cluster named `lab` already exists before creating one, avoiding the "cluster already exists" error on re-running the script. `kind create cluster` under the hood pulls a `kindest/node` image, starts it as a container, generates a kubeconfig, and merges it into `~/.kube/config`, switching your current context to `kind-lab`.

```sh
sh "$(dirname "$0")/ingress-setup.sh"
sh "$(dirname "$0")/vault-setup.sh"
```
Each platform dependency gets its own script, called with `sh` rather than executed directly (`./ingress-setup.sh`): `sh file` only needs the file to be *readable*, not marked executable, so neither script needs a `chmod +x`. This is the opposite tradeoff from `common.sh` above — `ingress-setup.sh` and `vault-setup.sh` don't need to hand anything back to `cluster-setup.sh`, they just need to run to completion, so isolating each in its own process is exactly right here, where it was wrong for `common.sh`.

Installing Vault this early is a convenience, not a curriculum choice: what it actually does, and why, is [Vault: secrets as a live service, not a file in git](vault-secrets.md)'s entire chapter. For now, `make cluster` just means Vault is already running by the time you get there.

### scripts/ingress-setup.sh

```sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
kubectl rollout status -n ingress-nginx deploy/ingress-nginx-controller --timeout=180s
```
Pin an exact controller release instead of `main`, since an unpinned branch reference can change out from under you between two runs of the same command on a manifest you're applying straight from the internet. `rollout status` blocks until the Deployment's Pods are actually Ready, not just created, so nothing later races against a controller that isn't listening yet.

`scripts/vault-setup.sh` is the third script `cluster-setup.sh` calls; it's walked through where it conceptually belongs, in [Vault: secrets as a live service, not a file in git](vault-secrets.md#install-vault-dev-mode).

## Cluster config for later chapters

The default `kind create cluster` has no port mappings, so an Ingress controller inside it is unreachable from your host machine. Miniflux's Ingress ([Raw manifests](raw-manifests.md)) needs `extraPortMappings`. `config/kind/kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - { containerPort: 80, hostPort: 80, protocol: TCP }
      - { containerPort: 443, hostPort: 443, protocol: TCP }
```

```sh
kind delete cluster --name lab
kind create cluster --name lab --config config/kind/kind-config.yaml
kubectl cluster-info
kubectl get nodes -o wide
```

`extraPortMappings` forwards ports from your host straight into the kind node container: this is what lets `curl http://miniflux.local/...` on your laptop reach the ingress-nginx controller running inside the cluster. ingress-nginx itself installs the same way [scripts/ingress-setup.sh](#scriptsingress-setupsh) does, above; the one thing that script doesn't do for you:

```sh
echo "127.0.0.1 miniflux.local" | sudo tee -a /etc/hosts
```

## Cluster-level exploration

```sh
kubectl get nodes -o wide
kubectl describe node lab-control-plane
kubectl get pods -n kube-system
kubectl version
kubectl api-resources
```

`kubectl get pods -n kube-system` shows the control plane components actually running as Pods (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `coredns`, `kindnet`, `kube-proxy`): a concrete look at what "the cluster" is actually made of underneath `kubectl`.

## Cleanup and reset

```sh
kind get clusters
kind delete cluster --name lab      # destroys everything, start clean
```

kind clusters are cheap and disposable even though the repo they build isn't: when the *cluster* gets into a confusing state from experimentation, deleting and recreating it is often faster than debugging it. Nothing about the repo itself is lost: `kubectl apply`/`helm install`/ArgoCD sync just run again against a fresh cluster.

## Try it

```sh
kind delete cluster --name lab
kind create cluster --name lab --config config/kind/kind-config.yaml
kubectl get nodes
```

Confirm you can tear down and rebuild the cluster in under a minute before moving on: this is the loop you'll be running constantly through [Miniflux, end to end](miniflux-deployment.md), it needs to be fast and unremarkable, not something to think about each time.
