# 16. Cheatsheet

## 16.1 Debugging flowchart

```
Pod not Running?
  kubectl get pods -o wide
  kubectl describe pod <name>          -> read Events at the bottom, this is 90% of debugging

  Pending            -> FailedScheduling in Events: insufficient resources, or unschedulable node
                         check: kubectl describe node <node>, kubectl top nodes
  ImagePullBackOff    -> wrong image name/tag, private registry auth missing
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
  kubectl logs -n argocd deploy/argocd-repo-server -c ksops   -> CMP render failures show up here

Secret not decrypting?
  kubectl exec -n argocd deploy/argocd-repo-server -c ksops -- ksops version   -> confirm the sidecar is even present
  SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -d apps/<app>/secrets.enc.yaml    -> confirm it decrypts locally at all
                                                                                   (must be an ABSOLUTE path)
```

## 16.2 kubectl commands by task

```sh
# context and namespace
kubectl config get-contexts
kubectl config use-context kind-k8s-deploy
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

# deployments
kubectl rollout status deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name> [--to-revision=N]
kubectl rollout restart deployment/<name>
kubectl scale deployment/<name> --replicas=N

# networking
kubectl port-forward svc/<name> <local>:<remote>
kubectl get endpoints <svc>

# rbac
kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<sa> [-n ns]

# helm
helm template <release> <chart>
helm lint <chart>
helm install|upgrade <release> <chart> [-f values.yaml] [--set k=v]
helm rollback <release> <revision>
helm history <release>

# kustomize + ksops (chapters 11-12)
kustomize build --enable-helm --enable-alpha-plugins --enable-exec --load-restrictor LoadRestrictionsNone <apps/x>
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -e -i apps/<x>/secrets.enc.yaml
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops apps/<x>/secrets.enc.yaml   # edit in place

# argocd
argocd app list
argocd app get <app>
argocd app sync <app>
argocd app diff <app>

# kind
kind create cluster --name k8s-deploy [--config file.yaml]
kind delete cluster --name k8s-deploy

# k3s (VPS, chapter 15)
sudo systemctl status k3s
sudo k3s kubectl get nodes
kubectl config use-context k3s-vps
sudo journalctl -u k3s -f              # control plane logs, single process

# postgres
kubectl exec -it postgres-0 -n platform -- psql -U postgres -c '\l'
kubectl exec -it postgres-0 -n platform -- psql -U postgres -c "ALTER ROLE miniflux WITH PASSWORD '...';"

# redis
kubectl exec -it redis-0 -n platform -- sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'

# kafka
kubectl exec -it kafka-0 -n platform -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

## 16.3 Glossary

| Term | One line |
|------|----------|
| apiserver | HTTP entrypoint to the cluster, everything goes through it |
| etcd | key-value store, actual source of truth backing every object |
| controller | reconciliation loop, drives actual state toward desired state |
| Pod | smallest deployable unit, one or more containers sharing network/storage |
| ReplicaSet | keeps N Pods matching a label selector alive |
| Deployment | manages ReplicaSets, adds rolling update and rollback |
| StatefulSet | Deployment variant with stable identity and per-replica storage |
| headless Service | `clusterIP: None`, no load balancing, DNS returns Pod IPs directly |
| Ingress | layer 7 HTTP router in front of Services, needs a controller to do anything |
| ConfigMap | non-sensitive config, consumed as env vars or mounted files |
| Secret | sensitive config, same mechanics as ConfigMap, base64 not encrypted |
| PV/PVC | durable storage: PV is the actual disk, PVC is a namespaced request for one |
| ServiceAccount | identity a Pod uses to authenticate to the K8s API |
| Role/RoleBinding | namespaced RBAC grant and its binding to a subject |
| SecurityContext | Linux-level privilege restrictions on a Pod/container |
| Helm chart | packaged, templated set of manifests plus default values |
| Kustomize | composes a rendered Helm chart with generated resources (like a decrypted Secret) into one output |
| age | keypair-based file encryption, the backend SOPS uses here |
| SOPS | encrypts specific fields of a file (a Secret's `data`/`stringData`) against an age key |
| ksops | the Kustomize generator plugin that runs SOPS decryption as part of `kustomize build` |
| Config Management Plugin (CMP) | a sidecar on `argocd-repo-server` that renders an app ArgoCD's built-in tooling can't (here: kustomize+helm+ksops together) |
| ArgoCD | GitOps controller, reconciles cluster state to match a git repo |
| sync wave | annotation ordering which Applications reconcile before which others |
| reconciliation loop | observe actual state, compare to desired state, act to close the gap, repeat forever |
| k3s | lightweight, single-binary Kubernetes distribution; used here to host real apps on one VPS (chapter 15) |
| cert-manager | issues/renews TLS certificates (e.g. Let's Encrypt) from annotations on an Ingress |
| KRaft | Kafka's own metadata-quorum mode (replaces ZooKeeper), lets a single broker Pod manage its own cluster metadata |
