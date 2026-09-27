# Cheatsheet

## Debugging

| Symptom | Check | Meaning |
|---|---|---|
| Pod not `Running` | `kubectl get pods -o wide` | first pass: which Pod, which node, which state |
| Pod not `Running` | `kubectl describe pod <name>` | read Events at the bottom, this is 90% of debugging |
| `Pending` | `kubectl describe node <node>`, `kubectl top nodes` | `FailedScheduling` in Events: insufficient resources, or an unschedulable node |
| `ImagePullBackOff` | N/A | wrong image name/tag, or private registry auth missing |
| `CrashLoopBackOff` | `kubectl logs <pod> --previous` | logs from the crashed instance, not the new one |
| `Init:0/1` stuck | see "Secret not injected" rows below | the Vault Agent init container never completed |
| Running but `0/1 Ready` | `kubectl describe pod`, check probe path/port | readinessProbe failing |
| Service not reachable | `kubectl get endpoints <svc>` | empty means the selector matches nothing, or matched Pods aren't Ready |
| Service not reachable | `kubectl get svc <svc> -o yaml` | confirm the selector matches the Pod labels exactly |
| Service not reachable | `kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- <svc>.<ns>` | test connectivity from inside the cluster |
| Secret not injected | `kubectl describe pod <pod> \| grep -A10 vault-agent-init` | the init container's own exit reason |
| Secret not injected | `kubectl logs <pod> -c vault-agent-init` | auth/policy errors show up here first |
| Secret not injected | `kubectl exec <pod> -c <app-container> -- cat /vault/secrets/<name>` | confirm the file actually rendered |
| Secret not injected | `kubectl exec <pod> -c <app-container> -- printenv \| grep <VAR>` | confirm the container's command sourced it |
| Secret not injected | `vault status` | `Sealed: true` means nothing decrypts, anywhere |
| Secret not injected | `vault read auth/kubernetes/role/<name>` | confirm `bound_service_account_name`/namespace match the Pod |
| ArgoCD app stuck OutOfSync/Degraded | `argocd app get <app>` | overall status |
| ArgoCD app stuck OutOfSync/Degraded | `argocd app diff <app>` | exact field-level diff between git and the live cluster |
| ArgoCD app stuck OutOfSync/Degraded | `kubectl describe application <app> -n argocd` | controller-side event detail |
| ArgoCD app stuck OutOfSync/Degraded | `kubectl logs -n argocd deploy/argocd-repo-server` | kustomize/helm render failures show up here |

## kubectl by task

| Task | Commands |
|---|---|
| Context and namespace | `kubectl config get-contexts` · `kubectl config use-context kind-lab` · `kubectl config set-context --current --namespace=<ns>` |
| Inspect | `kubectl get <kind> [-n ns] [-A] [-o wide\|yaml\|json]` · `kubectl describe <kind> <name>` · `kubectl explain <kind>.<field.path>` · `kubectl get events --sort-by=.lastTimestamp` |
| Logs and exec | `kubectl logs <pod> [-c container] [--previous] [-f]` · `kubectl exec -it <pod> [-c container] -- sh` · `kubectl cp <pod>:/path ./local-path` |
| Apply and lifecycle | `kubectl apply -f file.yaml` · `kubectl apply -k dir/` · `kubectl delete -f file.yaml` · `kubectl diff -f file.yaml` (dry-run diff before apply) |
| Deployments | `kubectl rollout status deployment/<name>` · `kubectl rollout history deployment/<name>` · `kubectl rollout undo deployment/<name> [--to-revision=N]` · `kubectl rollout restart deployment/<name>` · `kubectl scale deployment/<name> --replicas=N` |
| Networking | `kubectl port-forward svc/<name> <local>:<remote>` · `kubectl get endpoints <svc>` |
| RBAC | `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<sa> [-n ns]` |

## Helm

| Command | Notes |
|---|---|
| `helm template <release> <chart>` | pure client-side render, no cluster needed |
| `helm lint <chart>` | static check |
| `helm install\|upgrade <release> <chart> [-f values.yaml] [--set k=v]` | apply to cluster |
| `helm rollback <release> <revision>` | revert a release |
| `helm history <release>` | list prior revisions |

## Kustomize

| Command | Notes |
|---|---|
| `kustomize build --enable-helm --load-restrictor LoadRestrictionsNone <apps/x>` | [Kustomize inflating a Helm chart](kustomize-helm-inflation.md): required flags for every `apps/*` overlay in this repo |

## Vault

| Command | Notes |
|---|---|
| `vault status` | `Sealed: true` blocks everything |
| `vault kv get <path>` | read a secret |
| `vault kv put <path> KEY=value ...` | write/replace a secret |
| `vault policy list` / `vault policy read <name>` | inspect policies |
| `vault read auth/kubernetes/role/<name>` | inspect a role's bound ServiceAccount |
| `vault operator raft snapshot save <file>` | backup, production mode only |
| `vault operator unseal <key>` | required after every restart in production mode |
| `kubectl logs -n vault -l app.kubernetes.io/name=vault-agent-injector` | the injector webhook's own errors |

## ArgoCD

| Command | Notes |
|---|---|
| `argocd app list` | all Applications |
| `argocd app get <app>` | one Application's status |
| `argocd app sync <app>` | force a sync now |
| `argocd app diff <app>` | git vs live cluster |

## kind

| Command | Notes |
|---|---|
| `kind create cluster --name lab [--config k8s/kind-config.yaml]` | bring the local cluster up |
| `kind delete cluster --name lab` | tear it down |

## Postgres

| Command | Notes |
|---|---|
| `kubectl exec -it postgres-0 -n platform -c postgres -- psql -U postgres -c '\l'` | list databases |
| `kubectl exec -it postgres-0 -n platform -c postgres -- psql -U postgres -c "ALTER ROLE miniflux WITH PASSWORD '...';"` | rotate a role's password on the live instance |

## Glossary

| Term | One line |
|---|---|
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
| Secret | sensitive config, same mechanics as ConfigMap, base64 not encrypted; not used for app secrets in this repo (Vault is) |
| PV/PVC | durable storage: PV is the actual disk, PVC is a namespaced request for one |
| ServiceAccount | identity a Pod uses to authenticate to the K8s API, and (here) to Vault |
| Role/RoleBinding | namespaced RBAC grant and its binding to a subject |
| Helm chart | packaged, templated set of manifests plus default values |
| Kustomize | composes a rendered Helm chart into one output, namespace-stamped |
| Vault | live service holding secrets; a Pod fetches its own at startup, never stored in git |
| KV v2 secrets engine | Vault's versioned key-value store, the actual place secret values live |
| Kubernetes auth method | lets Vault trust a Pod's own ServiceAccount token as proof of identity |
| Vault policy | grants read/write on specific Vault paths, nothing broader |
| Vault role | binds a bound ServiceAccount name+namespace to a policy |
| Vault Agent Injector | mutating admission webhook that adds init+sidecar containers to a Pod, per annotation |
| unseal | production Vault's data is encrypted at rest; a threshold of unseal keys is required after every restart to use it |
| raft (integrated storage) | Vault's own persistent storage backend, no external database needed |
| ArgoCD | GitOps controller, reconciles cluster state to match a git repo |
| sync wave | annotation ordering which Applications reconcile before which others |
| app-of-apps | one root Application pointing at a directory of other Application manifests |
| reconciliation loop | observe actual state, compare to desired state, act to close the gap, repeat forever |
