# 13. Cheatsheet

## 13.1 Debugging flowchart

```
Pod not Running?
  kubectl get pods -o wide
  kubectl describe pod <name>          -> read Events at the bottom, this is 90% of debugging

  Pending            -> FailedScheduling in Events: insufficient resources, or unschedulable node
                         check: kubectl describe node <node>, kubectl top nodes
  ImagePullBackOff    -> wrong image name/tag, private registry auth missing, or
                         image never `kind load docker-image`-ed into this cluster
  CrashLoopBackOff     -> kubectl logs <pod> --previous   (logs from the crashed instance, not the new one)
  Running but 0/1 Ready -> readinessProbe failing, kubectl describe pod, check probe path/port

Service not reachable?
  kubectl get endpoints <svc>          -> empty means selector matches nothing, or matched Pods not Ready
  kubectl get svc <svc> -o yaml        -> confirm selector matches Pod labels exactly
  kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- <svc>.<ns>

Config/secret not applied?
  kubectl exec <pod> -- env                      (envFrom path)
  kubectl exec <pod> -- cat /path/to/file         (volume mount path)
  kubectl describe pod <pod> | grep -A5 Mounts    (confirm the volume is actually mounted where expected)

ArgoCD app stuck OutOfSync/Degraded?
  argocd app get <app>
  argocd app diff <app>              -> exact field-level diff between git and live cluster
  kubectl describe application <app> -n argocd

Vault secret not injected?
  kubectl get pods <pod> -o jsonpath='{.spec.containers[*].name}'   -> confirm agent sidecar is present
  kubectl logs <pod> -c vault-agent-init
  kubectl exec -it vault-0 -- vault kv get secret/<path>              -> confirm the secret actually exists
```

## 13.2 kubectl commands by task

```sh
# context and namespace
kubectl config get-contexts
kubectl config use-context kind-lab
kubectl config set-context --current --namespace=<ns>

# inspect
kubectl get <kind> [-n ns] [-A] [-o wide|yaml|json]
kubectl describe <kind> <name>
kubectl explain <kind>.<field.path>
kubectl get events --sort-by=.lastTimestamp

# logs and exec
kubectl logs <pod> [-c container] [--previous] [-f]
kubectl exec -it <pod> [-c container] -- sh
kubectl cp <pod>:/path ./local-path

# apply and lifecycle
kubectl apply -f file.yaml
kubectl delete -f file.yaml
kubectl diff -f file.yaml           # dry-run diff against live cluster before apply
kubectl apply -f file.yaml --dry-run=client -o yaml

# deployments
kubectl rollout status deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name> [--to-revision=N]
kubectl rollout restart deployment/<name>
kubectl scale deployment/<name> --replicas=N
kubectl set image deployment/<name> <container>=<image>:<tag>

# networking
kubectl port-forward svc/<name> <local>:<remote>
kubectl get endpoints <svc>

# rbac
kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<sa> [-n ns]

# helm
helm template <release> <chart>
helm install|upgrade <release> <chart> [-f values.yaml] [--set k=v]
helm rollback <release> <revision>
helm history <release>

# kind
kind create cluster --name lab [--config file.yaml]
kind load docker-image <image>:<tag> --name lab
kind delete cluster --name lab

# k3s (VPS, chapter 14)
sudo systemctl status k3s
sudo k3s kubectl get nodes
kubectl config use-context k3s-vps
sudo journalctl -u k3s -f              # control plane logs, single process
```

## 13.3 Glossary

| Term | One line |
|------|----------|
| apiserver | HTTP entrypoint to the cluster, everything goes through it |
| etcd | key-value store, actual source of truth backing every object |
| controller | reconciliation loop, drives actual state toward desired state |
| Pod | smallest deployable unit, one or more containers sharing network/storage |
| ReplicaSet | keeps N Pods matching a label selector alive |
| Deployment | manages ReplicaSets, adds rolling update and rollback |
| StatefulSet | Deployment variant with stable identity and per-replica storage |
| DaemonSet | one Pod per Node |
| Job/CronJob | run-to-completion workloads, optionally on a schedule |
| Service | stable virtual IP/DNS name load balancing across a set of Pods |
| Ingress | layer 7 HTTP router in front of Services, needs a controller to do anything |
| ConfigMap | non-sensitive config, consumed as env vars or mounted files |
| Secret | sensitive config, same mechanics as ConfigMap, base64 not encrypted |
| PV/PVC | durable storage: PV is the actual disk, PVC is a namespaced request for one |
| StorageClass | provisioner that creates PVs on demand |
| ServiceAccount | identity a Pod uses to authenticate to the K8s API (or Vault) |
| Role/RoleBinding | namespaced RBAC grant and its binding to a subject |
| SecurityContext | Linux-level privilege restrictions on a Pod/container |
| Helm chart | packaged, templated set of manifests plus default values |
| Vault | external secret manager, secrets never live in git |
| ArgoCD | GitOps controller, reconciles cluster state to match a git repo |
| reconciliation loop | observe actual state, compare to desired state, act to close the gap, repeat forever |
| k3s | lightweight, single-binary Kubernetes distribution; used here to host real apps on one VPS (chapter 14) |
| cert-manager | issues/renews TLS certificates (e.g. Let's Encrypt) from annotations on an Ingress |
