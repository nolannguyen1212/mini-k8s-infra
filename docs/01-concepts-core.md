# 1. Core concepts

## 1.1 What problem Kubernetes solves

You have containers (built with `docker build`). Running one container with `docker run` works on one machine. Kubernetes exists for the moment you have many containers, many machines, and need: restart on crash, scale up/down, roll out new versions without downtime, discover services by name instead of IP, schedule containers onto machines with free capacity, and recover from a machine dying.

Kubernetes is a control loop system. You declare desired state (YAML). Controllers continuously compare desired state to actual state and act to close the gap. This reconciliation loop is the single idea that explains almost every K8s behavior. When a Pod dies, nothing "restarts" it in the traditional sense, the Deployment controller notices actual replica count (2) does not match desired (3) and creates a new Pod.

## 1.2 Architecture

```
Control plane (brain, usually 1-3 nodes)
  kube-apiserver     entrypoint, validates and stores objects via etcd
  etcd               key-value store, the actual source of truth
  kube-scheduler      picks which Node a new Pod runs on
  kube-controller-manager   runs reconciliation loops (Deployment, Node, etc.)

Worker node (runs your workloads)
  kubelet            agent that talks to apiserver, starts/stops containers
  kube-proxy         programs iptables/ipvs rules for Service networking
  container runtime  containerd/CRI-O, actually runs containers
```

Everything you do with `kubectl` is an HTTP call to `kube-apiserver`. `kubectl apply -f x.yaml` sends the YAML as JSON to the apiserver, which validates it, stores it in etcd, and returns. Nothing runs yet at that point, controllers pick it up asynchronously.

In kind, all of this runs inside a single Docker container acting as a "node," which is why kind is good for learning but not representative of node-to-node networking in a real cluster.

## 1.3 The object model

Every Kubernetes object (Pod, Deployment, Service, ConfigMap, everything) shares the same envelope:

```yaml
apiVersion: apps/v1      # which API group/version defines this kind
kind: Deployment          # the object type
metadata:
  name: my-app             # unique name within the namespace
  namespace: default        # logical partition (see 1.5)
  labels:                   # arbitrary key/value used for selection
    app: my-app
spec:                      # desired state, you write this
  ...
status:                    # actual state, written by controllers, read only for you
  ...
```

Rule to internalize: you only ever author `spec`. `status` is filled in by the system. If you `kubectl get pod x -o yaml` and see a populated `status`, that came from a controller/kubelet reporting reality, not from your file.

`kubectl explain <kind>.<field>` reads this schema straight from the apiserver. This is faster and more reliable than searching docs:

```sh
kubectl explain deployment.spec.replicas
kubectl explain pod.spec.containers.resources
```

## 1.4 Pod

A Pod is the smallest deployable unit, not a container. A Pod is one or more containers that:

* share the same network namespace (same IP, can reach each other via `localhost`)
* share the same set of volumes if mounted into more than one container
* are always scheduled onto the same Node together
* live and die together (if any container needs replacing, the whole Pod is usually replaced)

Most Pods have exactly one container. Multi-container Pods exist for sidecar patterns (a log shipper, a service mesh proxy like Envoy, a Vault agent) where the sidecar needs to share network/filesystem with the main container.

Minimal Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: debug-shell
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
```

```sh
kubectl apply -f pod.yaml
kubectl get pods
kubectl exec -it debug-shell -- sh
kubectl logs debug-shell
kubectl delete pod debug-shell
```

You will almost never write a bare Pod in real work (see chapter 2, Deployment). Bare Pods are for throwaway debugging: if a Pod dies it is gone forever, nothing recreates it.

## 1.5 Namespace

A Namespace is a logical partition inside one cluster, used to separate teams/environments/apps. Most object types are namespaced (Pod, Deployment, ConfigMap, Secret). Some are cluster-wide (Node, PersistentVolume, ClusterRole, Namespace itself).

```sh
kubectl get namespaces
kubectl create namespace lab
kubectl get pods -n lab
kubectl config set-context --current --namespace=lab   # stop typing -n lab every time
```

Names only need to be unique within a namespace. `svc-a.lab.svc.cluster.local` and `svc-a.prod.svc.cluster.local` can both exist.

## 1.6 kubectl mental model

```sh
kubectl get <kind>              # list objects (actual state summary)
kubectl get <kind> <name> -o yaml   # full object as stored in etcd
kubectl describe <kind> <name>       # human readable, includes Events (the #1 debugging tool)
kubectl apply -f file.yaml            # create or update to match file (declarative)
kubectl delete -f file.yaml            # remove
kubectl logs <pod> [-c container]       # stdout/stderr of a container
kubectl exec -it <pod> -- sh             # shell into a running container
```

`kubectl describe` is the single most useful debugging command in Kubernetes. Its `Events` section at the bottom tells you exactly why a Pod is stuck (`ImagePullBackOff`, `FailedScheduling`, `CrashLoopBackOff` reason, etc).

## 1.7 Try it

```sh
kubectl apply -f ../deployment.yaml
kubectl get deployment nginx
kubectl get pods -l app=nginx
kubectl describe pod -l app=nginx | less
kubectl explain pod.spec.containers.resources.limits
```

Read the `Events` section of the describe output even though nothing is wrong, get familiar with what a healthy sequence looks like (`Scheduled` -> `Pulling` -> `Pulled` -> `Created` -> `Started`) so a broken sequence stands out later.
