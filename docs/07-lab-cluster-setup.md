# 7. Lab: cluster setup

## 7.1 What kind actually is

kind (Kubernetes IN Docker) runs each cluster "node" as a Docker container, with Kubernetes installed inside it. One control-plane container is enough for everything in this docs set. It is not a lightweight VM and not minikube, it is genuinely upstream Kubernetes, just packaged to boot in seconds on your laptop using Docker as the substrate instead of a VM or bare metal.

**Why kind over minikube for this docs set:** minikube runs the cluster inside a VM (or a single Docker container in driver=docker mode) and ships its own wrapper CLI, addon system, and mostly-single-node model, more moving parts, more magic hidden from you. kind is just Docker containers plus stock upstream Kubernetes, so `kubectl` behaves exactly like it would against any real cluster, multi-node configs are one YAML file away (useful for rehearsing node-level failures later), and cluster boot/teardown is fast enough to do many times a day while learning. Neither is "more real" than the other for API purposes, but kind's lower ceremony and multi-node story is why it is used here and why it is the more common choice in CI pipelines, which doubles as a transferable skill.

## 7.2 Walking through create-cluster.sh

The repo already has `create-cluster.sh` and `common.sh`. Read them alongside this section.

```sh
. "$(dirname "$0")/common.sh"
```
Sources shared logging helpers (`log_info`, `log_success`, etc) and a colorized `PS4` for `set -x` tracing. Never execute `common.sh` directly, it defines functions/vars for the calling shell, it does not do anything on its own.

```sh
set -e
set -x
```
`-e` aborts the script on the first failing command, `-x` echoes every command before running it. Together this gives you a script that fails loudly instead of silently continuing after an error, essential while learning since a silent partial failure is confusing to debug later.

```sh
brew install kind
```
Installs the kind CLI. Idempotent, brew no-ops if already installed.

```sh
if ! kind get clusters | grep -qx "lab"; then
  kind create cluster --name lab
fi
```
Checks whether a cluster named `lab` already exists before creating one, avoids the "cluster already exists" error on re-running the script. `kind create cluster` under the hood pulls a `kindest/node` image, starts it as a container, generates a kubeconfig, and merges it into `~/.kube/config`, switching your current context to `kind-lab`.

```sh
kubectl cluster-info
```
Confirms the apiserver is reachable and prints its URL, first sanity check after any cluster creation.

The rest of the script (`kubectl api-resources`, `kubectl explain deployment`, `kubectl get nodes/namespaces/pods -A`) is pure exploration, no side effects, safe to re-run any time you want to reorient yourself in a cluster.

```sh
sh create-cluster.sh
```

## 7.3 Cluster config for later chapters

The default `kind create cluster` has no port mappings, so an Ingress controller inside it is unreachable from your host machine. Chapter 3's Ingress lab and chapter 8's app lab need `extraPortMappings`. Delete and recreate with a config file:

```yaml
# kind-config.yaml
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
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
```

```sh
kind delete cluster --name lab
kind create cluster --name lab --config kind-config.yaml
kubectl cluster-info
kubectl get nodes -o wide
```

`extraPortMappings` forwards ports from your host straight into the kind node container, this is what lets `curl http://lab.local/...` on your laptop reach the ingress-nginx controller running inside the cluster.

## 7.4 Cluster level exploration

```sh
kubectl get nodes -o wide
kubectl describe node lab-control-plane
kubectl get pods -n kube-system
kubectl get componentstatuses 2>/dev/null || true   # deprecated in newer versions, may error, that is expected
kubectl version
kubectl api-resources
kubectl api-versions
```

`kubectl get pods -n kube-system` shows you the control plane components actually running as Pods (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `coredns`, `kindnet`, `kube-proxy`), a concrete look at the architecture diagram from chapter 1.

## 7.5 Cleanup and reset

```sh
kind get clusters
kind delete cluster --name lab      # destroys everything, start clean
```

Since kind clusters are cheap and disposable, when a cluster gets into a confusing state from experimentation, deleting and recreating is often faster than debugging it, this is one of the few contexts in this docs set where a destructive shortcut is the right call.
