# 2. GitOps and the repo layout

Every `kubectl apply` in chapter 1 was you, running a command from your laptop. GitOps flips this: a controller running inside the cluster continuously watches a git repository, and whatever is committed there is what gets applied, automatically, on every change. Git becomes the single source of truth, not your shell history. Chapter 7 installs that controller (ArgoCD) for real — this chapter lays out the repo shape everything from chapter 3 onward gets written into, so nothing later needs a detour to explain "why does this file live here."

## 2.1 The full repo, decided up front

This repo's root, once every chapter through 9 has run once:

```
charts/
  postgres/  miniflux/
apps/
  platform/
    postgres/                # kustomization.yaml (chart + values)
  miniflux/                  # same shape
argocd/
  values-argocd.yaml         # installs ArgoCD itself
  projects/default.yaml
  apps/                      # one Application per workload
  root.yaml
environments/
  namespace-platform.yaml  namespace-miniflux.yaml
  networkpolicy-platform-allow-consumers.yaml
```

No separate repo to create — `k8s/` (chapter 3's hand-applied exercise), `charts/`, `apps/`, and everything below live directly in this repo, alongside `docs/` itself.

No `.sops.yaml`, no `age/` keypair, no encrypted files anywhere in this tree. Chapter 6 deploys Vault as its own workload and secrets never sit in git in any form, encrypted or not — a Pod fetches its secret from Vault directly at startup, over the network, inside the cluster. That single decision is what removes SOPS+age's central cost from this repo entirely: rotating a secret later is a `vault kv put`, not a file edit plus a commit.

| Path | Contains | Changed by | Never contains |
|------|----------|------------|----------------|
| `charts/*` | what a workload *is* — Deployment/StatefulSet/Service shape | whoever owns that workload | any secret value, a specific namespace |
| `apps/*/kustomization.yaml` | which chart+values, which namespace | whoever deploys that workload | any secret value |
| `argocd/apps/*.yaml` | which repo path ArgoCD tracks, per workload | platform-level changes only | anything else |
| `environments/*` | namespaces, cross-cutting policy | rarely, only when topology changes | app-specific config |
| Vault (not in git at all) | actual secret values | `vault kv put`, directly, any time | — it's the one thing deliberately outside this repo |

The rule this table encodes: a git commit changes desired *state* — which chart, which values, which namespace — never a secret value. `apps/miniflux/kustomization.yaml` will eventually say "miniflux's Pod reads a secret injected from Vault," it will never say what that secret's value is.

## 2.2 Create the skeleton

```sh
mkdir -p charts apps/platform/postgres apps/miniflux argocd/apps argocd/projects environments
```

`.gitignore` — nothing secret-shaped needs excluding yet since no key material lives in this repo (unlike a SOPS+age setup), but Helm dependency downloads and local noise still do:

```sh
cat > .gitignore <<'EOF'
charts/**/charts/
charts/**/Chart.lock
.DS_Store
EOF
```

## 2.3 environments/: namespaces and policy as git-managed objects

Postgres and Miniflux live in separate namespaces on purpose from the start: `platform` for anything meant to be shared by more than one app later, `miniflux` for this one app's own objects. Both get created as git-managed objects now, not by a one-off `kubectl create namespace` that git never sees:

```sh
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
```

`environments/networkpolicy-platform-allow-consumers.yaml` — by default every Pod in a namespace can reach every other Pod in the cluster; a `NetworkPolicy` opts a namespace into a deny-by-default posture and then explicitly allows what should still work. Here: only Pods in the `miniflux` namespace may reach anything in `platform` (i.e. Postgres):

```sh
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

An empty `podSelector: {}` selects *every* Pod in `platform`. Adding a second consumer app later means adding one more `namespaceSelector` entry to this same `ingress.from` list, nothing else about this object changes.

```sh
kubectl apply -f environments/
kubectl get namespace platform miniflux
```

Applied by hand for now — chapter 7 hands this same directory to ArgoCD instead, nothing about the files themselves changes.

## 2.4 Try it

```sh
kubectl get ns platform miniflux
kubectl describe networkpolicy platform-allow-consumers -n platform
```

Note kind's default CNI (kindnet) does **not** enforce `NetworkPolicy` — this object is correct, but on a stock kind cluster it applies without error yet blocks nothing. Worth knowing before assuming this test proves more than it does: on a CNI that actually enforces `NetworkPolicy` (Calico, Cilium, k3s's default), the same object would genuinely block cross-namespace traffic; here it's still worth applying for the practice of writing it correctly, not for the isolation it doesn't yet provide.
