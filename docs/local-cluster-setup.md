# Local development cluster (kind)

- Runs on a local `kind` cluster for the whole docs set
- Not a disposable exercise environment: this is where the actual repo gets built and iterated on fastest

## What kind actually is

kind (Kubernetes IN Docker) runs each cluster "node" as a Docker container, with Kubernetes installed inside it. One control-plane container is enough for everything here. It is not a lightweight VM and not minikube, it is genuinely upstream Kubernetes, just packaged to boot in seconds on your laptop using Docker as the substrate instead of a VM or bare metal.

**Why kind over minikube:** minikube runs the cluster inside a VM (or a single Docker container in driver=docker mode) and ships its own wrapper CLI, addon system, and mostly-single-node model: more moving parts, more magic hidden from you. kind is just Docker containers plus stock upstream Kubernetes, so `kubectl` behaves exactly like it would against any real cluster, multi-node configs are one YAML file away, and cluster boot/teardown is fast enough to do many times a day. Neither is "more real" than the other for API purposes, but kind's lower ceremony is why it's used here and why it's the more common choice in CI pipelines: a transferable skill, not a toy.

## create-cluster.sh, and what it actually does

Everything from [GitOps and the repo layout](gitops-repo-layout.md) onward is a file inside this same repo (`k8s/`, `charts/`, `apps/` at the root, no separate repo to `git init`). `create-cluster.sh`/`common.sh`, already at this repo's root, are what actually bring the cluster up; walk through what they do once, rather than typing the same commands by hand:

```sh
. "$(dirname "$0")/common.sh"
```
Sources shared logging helpers (`log_info`, `log_success`, etc) and a colorized `PS4` for `set -x` tracing. Never execute `common.sh` directly, it defines functions/vars for the calling shell, it does nothing on its own.

```sh
set -e
set -x
```
`-e` aborts the script on the first failing command, `-x` echoes every command before running it. Together this gives you a script that fails loudly instead of silently continuing after an error.

```sh
CLUSTER=lab
KIND_CONFIG="$(dirname "$0")/k8s/kind-config.yaml"

command -v kind >/dev/null || brew install kind
```
The cluster is named `lab` throughout this repo's scripts: not the name of anything being deployed, just this local sandbox's own identity. `kind-config.yaml` lives at `k8s/kind-config.yaml` (see [Cluster config for later chapters](#cluster-config-for-later-chapters)), not the repo root.

```sh
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG"
fi
```
Checks whether a cluster named `lab` already exists before creating one, avoiding the "cluster already exists" error on re-running the script. `kind create cluster` under the hood pulls a `kindest/node` image, starts it as a container, generates a kubeconfig, and merges it into `~/.kube/config`, switching your current context to `kind-lab`.

```sh
docker ps --filter "name=^${CLUSTER}-control-plane$" --format '{{.Ports}}' \
  | grep -q '0.0.0.0:80->80/tcp' || {
    echo "Cluster '$CLUSTER' has no port 80 mapping."
    echo "Recreate it: kind delete cluster --name $CLUSTER"
    exit 1
  }
```
A real failure mode worth guarding against explicitly: if `kind-config.yaml`'s `extraPortMappings` (see [Cluster config for later chapters](#cluster-config-for-later-chapters)) ever get dropped (an edit that removes them, or a cluster created without `--config` at all), the cluster comes up looking healthy, and only later, silently, ingress-nginx becomes unreachable from the host. Checking the actual Docker port mapping right after creation turns that into a loud, immediate failure instead.

```sh
kubectl cluster-info
kubectl get nodes -o wide
```
Confirms the apiserver is reachable and prints its URL: the first sanity check after any cluster creation.

## Cluster config for later chapters

The default `kind create cluster` has no port mappings, so an Ingress controller inside it is unreachable from your host machine. Miniflux's Ingress ([The first real objects, by hand](first-objects-by-hand.md)) needs `extraPortMappings`. `k8s/kind-config.yaml`:

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
kind create cluster --name lab --config k8s/kind-config.yaml
kubectl cluster-info
kubectl get nodes -o wide
```

`extraPortMappings` forwards ports from your host straight into the kind node container: this is what lets `curl http://miniflux.local/...` on your laptop reach the ingress-nginx controller running inside the cluster.

Install ingress-nginx now, kind's own manifest variant (uses the `extraPortMappings` above instead of a cloud LoadBalancer). Pin an exact controller release instead of `main`, since an unpinned branch reference can change out from under you between two runs of the same command on a manifest you're applying straight from the internet:

```sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
kubectl rollout status -n ingress-nginx deploy/ingress-nginx-controller --timeout=180s
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
kind create cluster --name lab --config k8s/kind-config.yaml
kubectl get nodes
```

Confirm you can tear down and rebuild the cluster in under a minute before moving on: this is the loop you'll be running constantly through [Miniflux, end to end](miniflux-deployment.md), it needs to be fast and unremarkable, not something to think about each time.
