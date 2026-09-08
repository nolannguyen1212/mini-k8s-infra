# 11. ArgoCD

## 11.1 GitOps in one paragraph

Everything so far has been applied by you running `kubectl apply` or `helm install` from your laptop. GitOps flips this: a controller running inside the cluster continuously watches a git repository, and whatever is committed there is what gets applied, automatically, on every change. Git becomes the single source of truth (chapter README's principle 3), not your shell history. You stop running `kubectl apply` by hand entirely, you `git push` and the cluster converges to match on its own.

ArgoCD is that controller. It watches one or more git repos, renders the Kubernetes manifests found there (plain YAML, Kustomize, or a Helm chart), and continuously reconciles the live cluster state to match, the same reconciliation-loop idea from chapter 1.2, now applied to "does the cluster match git" instead of "does the Pod count match the Deployment spec."

## 11.2 Install ArgoCD

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=180s
```

Access the UI/API:

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Get the auto-generated admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

```sh
argocd login localhost:8080 --username admin --password <password-from-above> --insecure
```

## 11.3 Application: the core ArgoCD object

An `Application` tells ArgoCD which repo/path to watch and which cluster/namespace to apply it to.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: go-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-user>/mini-k8s-infra.git
    targetRevision: main
    path: charts/go-app          # the Helm chart built in chapter 9
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true        # delete resources removed from git
      selfHeal: true       # revert any manual kubectl edit back to match git
    syncOptions:
      - CreateNamespace=true
```

```sh
kubectl apply -f argocd/go-app-application.yaml
argocd app get go-app
argocd app sync go-app          # manual sync, unnecessary once automated is on, useful the first time
kubectl get pods -l app=go-app
```

`selfHeal: true` is the enforcement mechanism behind "git is the only source of truth": run `kubectl scale deployment go-app --replicas=10` by hand after this is set, and watch ArgoCD silently revert it back to whatever `replicaCount` says in git within seconds. This is expected behavior, not a bug, drift correction is the entire point.

## 11.4 App of apps pattern

Instead of manually applying one `Application` per service, commit an `Application` that itself points at a directory of `Application` manifests, one per service. Apply that single root Application once, everything else self-registers from git.

```
argocd/
  root-app.yaml
  apps/
    go-app.yaml
    js-app.yaml
    vault.yaml
```

`argocd/root-app.yaml`:

```yaml
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
    automated:
      prune: true
      selfHeal: true
```

```sh
kubectl apply -f argocd/root-app.yaml
argocd app list
```

From this point forward, adding a new service to the cluster is: write its chart under `charts/`, add one `Application` file under `argocd/apps/`, commit, push. Nothing is run against the cluster by hand.

## 11.5 Sync waves for ordering

Some resources must exist before others (Vault before an app that injects secrets from it). `sync-wave` annotations order reconciliation, lower numbers first.

```yaml
metadata:
  name: vault
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

```yaml
metadata:
  name: js-app
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

## 11.6 Try it

```sh
git clone <your-repo>
# edit charts/go-app/values.yaml: bump replicaCount
git add charts/go-app/values.yaml
git commit -m "scale go-app to 4 replicas"
git push
argocd app get go-app --refresh
kubectl get deployment go-app -o jsonpath='{.spec.replicas}'
```

Watch the Application go `OutOfSync` right after the push, then `Synced` once ArgoCD's polling interval (default 3 minutes, or immediately via `argocd app sync go-app` / a webhook) picks up the change, with zero `kubectl` commands run against the cluster.
