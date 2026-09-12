# 14. App-of-apps, sync waves, and the GitOps repo layout

## 14.1 The full repo, and what lives where

Everything built since chapter 7:

```
k8s-deploy/
  .sops.yaml
  age/
    keys.txt                 # gitignored, never committed
  charts/
    postgres/  redis/  kafka/  minio/  miniflux/
  apps/
    platform/
      postgres/  redis/  kafka/  minio/     # kustomization.yaml + ksops-generator.yaml + secrets.enc.yaml
    miniflux/                                # same shape
  argocd/
    values-argocd.yaml       # installs ArgoCD itself, with the ksops sidecar
    cmp/ksops-cmp.yaml
    projects/default.yaml
    apps/                     # one Application per workload
    root.yaml
  environments/
    namespace-platform.yaml  namespace-miniflux.yaml
    networkpolicy-platform-allow-consumers.yaml
```

| Path | Contains | Changed by | Never contains |
|------|----------|------------|----------------|
| `charts/*` | what a workload *is* — Deployment/StatefulSet/Service shape | whoever owns that workload | plaintext secrets, a specific namespace |
| `apps/*/kustomization.yaml` | which chart+values, which namespace | whoever deploys that workload | plaintext secrets |
| `apps/*/secrets.enc.yaml` | actual secret values, encrypted | rotated independently of everything else | plaintext, ever, on disk |
| `argocd/apps/*.yaml` | which repo path ArgoCD tracks, per workload | platform-level changes only | anything else |
| `environments/*` | namespaces, cross-cutting policy | rarely, only when topology changes | app-specific config |

The rule this table encodes: a git commit changes desired state, never a secret value directly — `apps/miniflux/kustomization.yaml` says "miniflux reads a Secret decrypted from `secrets.enc.yaml`," it never says what that secret's value is.

## 14.2 environments/: namespaces and policy as git-managed objects

Chapter 8 created `platform` and `miniflux` namespaces and a NetworkPolicy by hand, with `kubectl create`/`kubectl apply`. From here on those are git-managed objects too, exactly like everything else:

```sh
mkdir -p environments
cat > environments/namespace-platform.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: platform
EOF
cat > environments/namespace-miniflux.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: miniflux
EOF
cat > environments/networkpolicy-platform-allow-consumers.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: platform-allow-consumers
  namespace: platform
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: miniflux }
EOF
```

An empty `podSelector: {}` selects *every* Pod in `platform` — this is chapter 3.5's rule again, now protecting the whole namespace, not just Postgres specifically. Adding a second app later means adding one more `namespaceSelector` entry to this same `ingress.from` list, nothing else about this object changes.

## 14.3 The AppProject

```sh
mkdir -p argocd/projects
cat > argocd/projects/default.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  sourceRepos:
    - "https://github.com/<your-user>/k8s-deploy.git"
  destinations:
    - { namespace: platform, server: https://kubernetes.default.svc }
    - { namespace: miniflux, server: https://kubernetes.default.svc }
  clusterResourceWhitelist:
    - { group: "", kind: Namespace }
EOF
```

`clusterResourceWhitelist` is required for anything cluster-scoped, `Namespace` included — without it, the `environments` `Application` below would sync every namespaced object it manages but silently skip the `Namespace` objects themselves.

## 14.4 One Application per workload, and sync-wave ordering

Some resources must exist before others: namespaces before anything lands in them, the data layer before an app whose readiness probe depends on it. `sync-wave` annotations order reconciliation, lower numbers first, everything in the same wave applies together.

```sh
mkdir -p argocd/apps
```

`argocd/apps/environments.yaml` — plain YAML, no chart, no secret, ArgoCD's built-in directory handling is the right tool:

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
    repoURL: https://github.com/<your-user>/k8s-deploy.git
    targetRevision: main
    path: environments
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

`argocd/apps/platform-postgres.yaml` (repeat for `platform-redis`, `platform-kafka`, `platform-minio`, changing only `name`/`path`/`namespace`):

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
    repoURL: https://github.com/<your-user>/k8s-deploy.git
    targetRevision: main
    path: apps/platform/postgres
    plugin:
      name: ksops-kustomize
  destination:
    server: https://kubernetes.default.svc
    namespace: platform
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

`argocd/apps/miniflux.yaml` (chapter 13.6's example, unchanged, reproduced here for the full set):

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
    repoURL: https://github.com/<your-user>/k8s-deploy.git
    targetRevision: main
    path: apps/miniflux
    plugin:
      name: ksops-kustomize
  destination:
    server: https://kubernetes.default.svc
    namespace: miniflux
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

Three tiers: `environments` (`-2`, namespaces+policy must exist first) → `platform-*` (`-1`, the datastore miniflux's readiness probe depends on) → `miniflux` (`0`).

## 14.5 The app-of-apps pattern

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
    repoURL: https://github.com/<your-user>/k8s-deploy.git
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

From this point forward, adding a workload is: write its chart, add one overlay under `apps/`, add one `Application` file under `argocd/apps/`, commit, push. Nothing else is ever run against the cluster by hand.

## 14.6 The reconciliation chain, end to end

```
developer commits to charts/miniflux/values.yaml
        |
        v
   git push to main
        |
        v
ArgoCD polls repo, detects diff (OutOfSync)
        |
        v
ksops CMP sidecar runs: kustomize build (inflates the Helm chart, decrypts the Secret)
        |
        v
ArgoCD applies rendered manifests to the cluster
        |
        v
Deployment controller reconciles ReplicaSet/Pods to match (chapter 2)
        |
        v
kubelet on the Node starts/stops containers (chapter 1)
        |
        v
miniflux's Pod reads DATABASE_URL from the decrypted Secret at process start
```

Four independent reconciliation loops stacked here: ArgoCD (git to cluster objects), the Deployment controller (spec to Pods), kubelet (Pod spec to running containers), and the ksops CMP itself (encrypted file to rendered Secret) sitting one layer earlier than the other three. Each layer only cares about the layer directly below it — a stuck rollout is a chapter 2 problem, a stuck sync is a chapter 13 problem, a Secret with the wrong value is a chapter 12 problem, they don't need to be reasoned about all at once.

## 14.7 Promoting to a new environment

Because config is fully split from the chart (`values.yaml` vs `values-prod.yaml`, chapter 9.3), standing up a second environment is one more overlay directory and one more `Application`, not new charts:

```sh
cp charts/miniflux/values.yaml charts/miniflux/values-staging.yaml
# edit replica count / host for staging

mkdir -p apps/miniflux-staging
cat > apps/miniflux-staging/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: miniflux-staging

helmGlobals:
  chartHome: ../../charts

helmCharts:
  - name: miniflux
    releaseName: miniflux
    namespace: miniflux-staging
    valuesFile: ../../charts/miniflux/values-staging.yaml

generators:
  - ksops-generator.yaml
EOF
cp apps/miniflux/ksops-generator.yaml apps/miniflux-staging/ksops-generator.yaml
sops -d apps/miniflux/secrets.enc.yaml > apps/miniflux-staging/secrets.enc.yaml   # start from the same values, then edit if staging needs its own
sops -e -i apps/miniflux-staging/secrets.enc.yaml
```

The overlay's `valuesFile:` is what picks the environment, not anything on the `Application` object — the CMP plugin (13.3) runs the identical `kustomize build` command regardless of which `apps/*` directory ArgoCD points it at:

```yaml
# argocd/apps/miniflux-staging.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: miniflux-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-user>/k8s-deploy.git
    targetRevision: main
    path: apps/miniflux-staging
    plugin:
      name: ksops-kustomize
  destination:
    server: https://kubernetes.default.svc
    namespace: miniflux-staging
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

Same chart, same repo, a second overlay directory, a different namespace — this is also exactly the mechanism chapter 15 uses to go from this local kind cluster to a real, permanently-running VPS: same repo, a different `destination.server`, nothing else changes.

## 14.8 Try it

1. Delete the kind cluster entirely, recreate it from chapter 7, reinstall ArgoCD (chapter 13), apply `argocd/root.yaml`, and get the whole stack healthy again without looking back at earlier chapters. This is the real test of whether the reconciliation chain is understood, not memorized.
2. Break something on purpose: scale `miniflux` manually and watch ArgoCD self-heal it (13.6), delete `postgres-0` and watch the StatefulSet recreate it (chapter 2/8), then fix a real config change via a git commit, never `kubectl`.
3. Explain out loud, without notes, why `postgres-secret`'s `MINIFLUX_DB_PASSWORD` and `miniflux-secret`'s `DATABASE_URL` are two separate encrypted files instead of one. If you can defend that, chapters 10-12's material is solid.
