# ArgoCD: git becomes the source of truth

- [GitOps and the repo layout](gitops-repo-layout.md) described GitOps in one paragraph
- This chapter installs the controller that actually makes it true: ArgoCD watches a git repo, renders whatever it finds there, and continuously reconciles the live cluster to match
- The same reconciliation-loop idea behind a Deployment or a StatefulSet, now applied to "does the cluster match git" instead of "does the Pod count match the spec"

## Install via Helm

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
```

`argocd/values-argocd.yaml`: the one setting this repo actually needs is `kustomize.buildOptions`, so `argocd-repo-server` renders every `apps/*` overlay with the same flags [Kustomize inflating a Helm chart](kustomize-helm-inflation.md) and [Vault: secrets as a live service, not a file in git](vault-secrets.md) already ran by hand:

```yaml
configs:
  cm:
    kustomize.buildOptions: "--enable-helm --load-restrictor LoadRestrictionsNone"
```

Worth noticing what's *not* here, compared to a SOPS+ksops-based install: no extra sidecar container on `repo-server`, no mounted decryption key, no Config Management Plugin. `argocd-repo-server`'s job is only "render the manifests": Vault injection happens later, at Pod admission ([The mechanical difference this creates](vault-secrets.md#the-mechanical-difference-this-creates)), completely independent of how the Pod was created. ArgoCD never needs to know Vault exists.

```sh
helm install argocd argo/argo-cd -n argocd -f argocd/values-argocd.yaml
kubectl wait --for=condition=available deployment/argocd-repo-server -n argocd --timeout=180s
```

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
argocd login localhost:8080 --username admin --password <password-from-above> --insecure
```

## The AppProject

An `AppProject` scopes what any `Application` inside it is allowed to touch: which repos, which destinations:

```sh
cat > argocd/projects/default.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  sourceRepos:
    - "https://github.com/<your-user>/mini-k8s-infra.git"
  destinations:
    - { namespace: platform, server: https://kubernetes.default.svc }
    - { namespace: miniflux, server: https://kubernetes.default.svc }
  clusterResourceWhitelist:
    - { group: "", kind: Namespace }
EOF
```

`clusterResourceWhitelist` is required for anything cluster-scoped, `Namespace` included: without it, the `environments` `Application` below would sync every namespaced object it manages but silently skip the `Namespace` objects themselves.

## One Application per workload, and sync-wave ordering

Some resources must exist before others: namespaces before anything lands in them, the data layer before an app whose readiness probe depends on it. `sync-wave` annotations order reconciliation, lower numbers first, everything in the same wave applies together.

`argocd/apps/environments.yaml`: plain YAML, no chart, ArgoCD's built-in directory handling is the right tool:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: environments
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: https://github.com/<your-user>/mini-k8s-infra.git
    targetRevision: main
    path: environments
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

`argocd/apps/platform-postgres.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-postgres
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: https://github.com/<your-user>/mini-k8s-infra.git
    targetRevision: main
    path: apps/platform/postgres
  destination:
    server: https://kubernetes.default.svc
    namespace: platform
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

`argocd/apps/miniflux.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: miniflux
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/<your-user>/mini-k8s-infra.git
    targetRevision: main
    path: apps/miniflux
  destination:
    server: https://kubernetes.default.svc
    namespace: miniflux
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

Three tiers: `environments` (`-2`, namespaces+policy must exist first) → `platform-postgres` (`-1`, the datastore Miniflux's readiness probe depends on) → `miniflux` (`0`). No `source.plugin` field on either: unlike a ksops-based setup, there's no custom plugin to route through; ArgoCD's own built-in Kustomize support, configured once via `kustomize.buildOptions` ([Install via Helm](#install-via-helm)), is enough.

`selfHeal: true` is the enforcement mechanism behind "git is the only source of truth": run `kubectl scale deployment miniflux --replicas=10 -n miniflux` by hand after this syncs, and watch ArgoCD revert it back to whatever the chart's `values.yaml` says within seconds.

## The app-of-apps pattern

Instead of manually applying one `Application` per workload, commit an `Application` that itself points at a directory of `Application` manifests. Apply that single root `Application` once, everything else self-registers from git:

```sh
cat > argocd/root.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-user>/mini-k8s-infra.git
    targetRevision: main
    path: argocd/apps
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
EOF
```

```sh
kubectl apply -f argocd/projects/default.yaml
kubectl apply -f argocd/root.yaml
argocd app list
```

From this point forward, adding a workload is: write its chart, add one overlay under `apps/`, add one `Application` file under `argocd/apps/`, commit, push. Nothing else is ever run against the cluster by hand: [Miniflux, end to end](miniflux-deployment.md) does exactly this, end to end, for the Postgres+Miniflux stack already built.

## Try it

```sh
argocd app get platform-postgres
argocd app get miniflux
kubectl get pods -n platform -n miniflux
```

Both Applications should reach `Synced`/`Healthy` without a `plugin:` field, and both Pods should show extra containers from Vault's injector ([Try it](vault-secrets.md#try-it)) despite having been created by ArgoCD instead of `helm upgrade --install` by hand: confirming injection really is independent of who created the Pod.
