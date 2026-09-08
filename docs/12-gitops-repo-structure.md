# 12. GitOps repo structure

## 12.1 Final layout

Everything built in chapters 7 to 11, as one repo:

```
mini-k8s-infra/
  create-cluster.sh
  common.sh
  docs/

  apps/
    go-app/
      main.go
      config.yaml
      Dockerfile
    js-app/
      server.js
      package.json
      .env.example
      Dockerfile

  charts/
    go-app/
      Chart.yaml
      values.yaml
      values-prod.yaml
      templates/
    js-app/
      Chart.yaml
      values.yaml
      values-prod.yaml
      templates/

  argocd/
    root-app.yaml
    apps/
      go-app.yaml
      js-app.yaml
      vault.yaml
```

Each app's `k8s/` raw manifests from chapter 8 are superseded by the Helm chart from chapter 9, do not keep both, the chart is the deployable artifact from chapter 9 onward.

## 12.2 What lives where, and why

| Path | Contains | Changed by | Never contains |
|------|----------|------------|----------------|
| `apps/*/` | application source, Dockerfile | app developers | cluster-specific config |
| `charts/*/values.yaml` | default (dev-like) config | whoever owns the service | plaintext secrets |
| `charts/*/values-prod.yaml` | prod overrides | whoever owns the service, reviewed | plaintext secrets |
| `argocd/apps/*.yaml` | which chart+values ArgoCD tracks, per environment | platform/infra | anything else |
| Vault | actual secret values | rotated independently of git | — |

The rule this table encodes: a git commit changes desired state, never a secret value directly. `values.yaml` says "js-app reads a secret named `js-app/config` from Vault at role `js-app`," it never says what that secret's value is.

## 12.3 End to end flow

```
developer commits to charts/go-app/values.yaml
        |
        v
   git push to main
        |
        v
ArgoCD polls repo, detects diff (OutOfSync)
        |
        v
ArgoCD renders charts/go-app via helm template
        |
        v
ArgoCD applies rendered manifests to the cluster (kubectl apply equivalent)
        |
        v
Deployment controller reconciles ReplicaSet/Pods to match (chapter 2)
        |
        v
kubelet on the Node starts/stops containers (chapter 1)
        |
        v
Pod requests a secret via Vault Agent Injector sidecar, using its
ServiceAccount identity (chapters 6 and 10), never from git
```

Three independent reconciliation loops are stacked here: ArgoCD (git to cluster objects), the Deployment controller (spec to Pods), and kubelet (Pod spec to running containers). Each layer only cares about the layer directly below it, none of them know about the layers above. This separation is why the system is debuggable: a stuck rollout is a chapter 2 problem, a stuck sync is a chapter 11 problem, a missing secret is a chapter 10 problem, they do not need to be reasoned about all at once.

## 12.4 Promoting to a new environment

Because config is fully split from the chart, standing up a second environment (say, `staging`) is:

```sh
cp charts/go-app/values-prod.yaml charts/go-app/values-staging.yaml
# edit replica counts / feature flags for staging
```

```yaml
# argocd/apps/go-app-staging.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: go-app-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-user>/mini-k8s-infra.git
    targetRevision: main
    path: charts/go-app
    helm:
      valueFiles: ["values-staging.yaml"]
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

Same chart, same image, different `values` file, different namespace. No manifest duplication, no drift between environments beyond what is explicitly declared in the values file diff.

This is also exactly the mechanism used to go from the disposable kind cluster to a real, permanently-running VPS: same repo, same chart, a `values-prod.yaml`, just a different destination cluster. Chapter 14 walks through standing up that second cluster on k3s and pointing this same GitOps setup at it.

## 12.5 What to actually rehearse before calling this "known"

1. Delete the kind cluster entirely, recreate it from `create-cluster.sh` plus the config from chapter 7.3, reinstall ingress-nginx, Vault, and ArgoCD, apply `root-app.yaml`, and get both apps healthy again without looking at these docs. This is the real test of whether the GitOps loop is understood, not memorized.
2. Break something on purpose: scale a Deployment manually and watch ArgoCD self-heal it (11.3), delete a Pod and watch the ReplicaSet recreate it (chapter 2), delete a Vault secret and watch the injector sidecar fail (chapter 10), then fix it via a git commit, not `kubectl`.
3. Explain out loud, without notes, why the js-app Secret lives in Vault instead of a committed YAML file, and why go-app uses a ConfigMap volume mount while js-app uses `envFrom`. If you can defend both, chapter 5's material is solid.
