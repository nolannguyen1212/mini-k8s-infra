# 7. Local development cluster (kind)

Everything from this chapter through chapter 14 runs on a local `kind` cluster before chapter 15 points the same repo at a real VPS. This is not a disposable exercise environment, it's just where the actual repo gets built and iterated on fastest, before it ever needs to survive a reboot.

## 7.1 What kind actually is

kind (Kubernetes IN Docker) runs each cluster "node" as a Docker container, with Kubernetes installed inside it. One control-plane container is enough for everything in this docs set. It is not a lightweight VM and not minikube, it is genuinely upstream Kubernetes, just packaged to boot in seconds on your laptop using Docker as the substrate instead of a VM or bare metal.

**Why kind over minikube:** minikube runs the cluster inside a VM (or a single Docker container in driver=docker mode) and ships its own wrapper CLI, addon system, and mostly-single-node model, more moving parts, more magic hidden from you. kind is just Docker containers plus stock upstream Kubernetes, so `kubectl` behaves exactly like it would against any real cluster, multi-node configs are one YAML file away, and cluster boot/teardown is fast enough to do many times a day. Neither is "more real" than the other for API purposes, but kind's lower ceremony is why it is used here and why it is the more common choice in CI pipelines, which doubles as a transferable skill.

## 7.2 Create the repo, then the cluster

```sh
mkdir k8s-deploy && cd k8s-deploy
git init
```

Everything from chapter 8 onward is a file inside this repo. `create-cluster.sh`/`common.sh` (in `mini-k8s-infra`, this docs repo) show the mechanics, walk through them once, then run the equivalent commands from inside `k8s-deploy`:

```sh
. "$(dirname "$0")/common.sh"
```
Sources shared logging helpers (`log_info`, `log_success`, etc) and a colorized `PS4` for `set -x` tracing. Never execute `common.sh` directly, it defines functions/vars for the calling shell, it does not do anything on its own.

```sh
set -e
set -x
```
`-e` aborts the script on the first failing command, `-x` echoes every command before running it. Together this gives you a script that fails loudly instead of silently continuing after an error.

```sh
brew install kind
```
Installs the kind CLI. Idempotent, brew no-ops if already installed.

```sh
if ! kind get clusters | grep -qx "k8s-deploy"; then
  kind create cluster --name k8s-deploy
fi
```
Checks whether a cluster named `k8s-deploy` already exists before creating one, avoids the "cluster already exists" error on re-running the script. `kind create cluster` under the hood pulls a `kindest/node` image, starts it as a container, generates a kubeconfig, and merges it into `~/.kube/config`, switching your current context to `kind-k8s-deploy`.

```sh
kubectl cluster-info
```
Confirms the apiserver is reachable and prints its URL, first sanity check after any cluster creation.

## 7.3 Cluster config for later chapters

The default `kind create cluster` has no port mappings, so an Ingress controller inside it is unreachable from your host machine. Chapter 3's Ingress example and chapter 8's app need `extraPortMappings`. Delete and recreate with a config file:

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
kind delete cluster --name k8s-deploy
kind create cluster --name k8s-deploy --config kind-config.yaml
kubectl cluster-info
kubectl get nodes -o wide
```

`extraPortMappings` forwards ports from your host straight into the kind node container, this is what lets `curl http://miniflux.local/...` on your laptop reach the ingress-nginx controller running inside the cluster.

Chapter 9 also runs a Kafka broker in this cluster, which defaults to a fairly large JVM heap. If Docker Desktop is capped low (under ~4GB), bump it in Docker Desktop's settings before then, or set `KAFKA_HEAP_OPTS=-Xmx512m -Xms512m` on the Kafka container, which is plenty for a single-broker instance.

## 7.4 Cluster level exploration

```sh
kubectl get nodes -o wide
kubectl describe node k8s-deploy-control-plane
kubectl get pods -n kube-system
kubectl version
kubectl api-resources
kubectl api-versions
```

`kubectl get pods -n kube-system` shows you the control plane components actually running as Pods (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `coredns`, `kindnet`, `kube-proxy`), a concrete look at the architecture diagram from chapter 1.

## 7.5 Cleanup and reset

```sh
kind get clusters
kind delete cluster --name k8s-deploy      # destroys everything, start clean
```

kind clusters are cheap and disposable even though the repo they build isn't: when the *cluster* gets into a confusing state from experimentation, deleting and recreating it is often faster than debugging it. Nothing about the repo itself is lost, `kubectl apply`/`helm install`/ArgoCD sync just run again against a fresh cluster.

## 7.6 Try it

```sh
kind delete cluster --name k8s-deploy
kind create cluster --name k8s-deploy --config kind-config.yaml
kubectl get nodes
```

Confirm you can tear down and rebuild the cluster in under a minute before moving on — this is the loop you'll be running constantly through chapter 14, it needs to be fast and unremarkable, not something to think about each time.
