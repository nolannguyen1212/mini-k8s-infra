# 13. ArgoCD, with the ksops plugin from the start

## 13.1 GitOps in one paragraph

Every `kubectl apply` so far has been you, running a command from your laptop. GitOps flips this: a controller running inside the cluster continuously watches a git repository, and whatever is committed there is what gets applied, automatically, on every change. Git becomes the single source of truth, not your shell history. ArgoCD is that controller — it watches a repo, renders whatever it finds there (plain YAML, Helm, Kustomize), and continuously reconciles the live cluster to match, the same reconciliation-loop idea from chapter 1, now applied to "does the cluster match git" instead of "does the Pod count match the Deployment spec."

## 13.2 Why install via Helm

ArgoCD's own `repo-server` Pod needs an *extra container* — a sidecar bundling `kustomize`+`ksops`+`sops`, decrypting every app's `secrets.enc.yaml` at render time. There is no supported way to add a sidecar to a Deployment ArgoCD's raw install manifest owns without hand-patching it, and having that patch silently reverted the next time the manifest is reapplied. The `argo-helm/argo-cd` chart exposes this as a documented values field instead — every app built from here on needs the sidecar, so this is simply how ArgoCD is installed, not a later upgrade from something simpler.

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

Do **not** `helm install` yet — chapter 10.5's secret-zero bootstrap has to exist first, the repo-server Pod this chart creates mounts a volume from the `sops-age` Secret and fails to start without it:

```sh
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic sops-age -n argocd --from-file=age.agekey=age/keys.txt
```

## 13.3 The CMP sidecar, and the plugin it runs

`argocd/cmp/ksops-cmp.yaml` — mounted into the sidecar at `/home/argocd/cmp-server/config/plugin.yaml`, telling ArgoCD's `cmp-server` process how to render an app:

```sh
mkdir -p argocd/cmp
cat > argocd/cmp/ksops-cmp.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ksops-cmp-plugin
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: ksops-kustomize
    spec:
      version: v1.0
      generate:
        command: ["sh", "-c"]
        args:
          - kustomize build --enable-helm --enable-alpha-plugins --enable-exec --load-restrictor LoadRestrictionsNone .
      discover:
        find:
          glob: "./kustomization.yaml"
EOF
```

`generate.args` is exactly the command chapters 11-12 already ran by hand, over and over, to verify each app locally — every flag here was already explained once, at the point it was needed.

## 13.4 Wiring the sidecar into the chart

`argocd/values-argocd.yaml`:

```yaml
configs:
  cm:
    # Only relevant if an app ever skips the explicit plugin override in
    # chapter 14's Application manifests — kept in sync with the CMP's own
    # flags anyway so that mistake fails safely instead of silently.
    kustomize.buildOptions: "--enable-helm --enable-alpha-plugins --enable-exec --load-restrictor LoadRestrictionsNone"

repoServer:
  extraContainers:
    - name: ksops
      # Bundles kustomize + ksops + sops in one image maintained by the
      # ksops project for exactly this sidecar pattern. Pin an exact tag —
      # check https://github.com/viaduct-ai/kustomize-sops for the current
      # one, "latest" defeats the point of a reproducible pipeline.
      image: viaductoss/ksops:v4.3.2
      command: ["/var/run/argocd/argocd-cmp-server"]
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
      env:
        - name: SOPS_AGE_KEY_FILE
          value: /etc/sops-age/age.agekey   # absolute path — chapter 12.3's gotcha, still applies here
      volumeMounts:
        # var-files and plugins are provided automatically by this chart
        # for any repoServer.extraContainers entry, do not redeclare them.
        - { name: var-files, mountPath: /var/run/argocd }
        - { name: plugins, mountPath: /home/argocd/cmp-server/plugins }
        - { name: ksops-cmp-plugin, mountPath: /home/argocd/cmp-server/config/plugin.yaml, subPath: plugin.yaml }
        - { name: cmp-tmp, mountPath: /tmp }
        - { name: sops-age, mountPath: /etc/sops-age, readOnly: true }

  volumes:
    - name: ksops-cmp-plugin
      configMap:
        name: ksops-cmp-plugin
    - name: cmp-tmp
      emptyDir: {}
    - name: sops-age
      secret:
        secretName: sops-age
```

Verify the `viaductoss/ksops` image tag and the exact `repoServer.extraContainers`/volume field names against the `argo-helm/argo-cd` chart's own current README before a real install — both shift across releases, and a mismatch fails at `helm install` time with a clear schema error, not silently.

## 13.5 Install

```sh
kubectl apply -f argocd/cmp/ksops-cmp.yaml -n argocd
helm install argocd argo/argo-cd -n argocd -f argocd/values-argocd.yaml
kubectl wait --for=condition=available deployment/argocd-repo-server -n argocd --timeout=180s
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

The repo-server Pod should show **2/2** containers ready, not 1/1 — the second is the ksops sidecar.

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
argocd login localhost:8080 --username admin --password <password-from-above> --insecure
```

## 13.6 The Application object

An `Application` tells ArgoCD which repo/path to watch, which cluster/namespace to apply to, and — for anything with a `kustomization.yaml` — which plugin renders it:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: miniflux
  namespace: argocd
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

`source.plugin.name: ksops-kustomize` is required, not cosmetic: a bare directory with a `kustomization.yaml` is normally picked up by ArgoCD's own built-in kustomize handling, which knows nothing about `--enable-helm` or the ksops exec plugin. Without this field, ArgoCD renders the wrong thing silently instead of routing through 13.3's sidecar. `selfHeal: true` is the enforcement mechanism behind "git is the only source of truth": run `kubectl scale deployment miniflux --replicas=10 -n miniflux` by hand after this syncs, and watch ArgoCD revert it back to whatever the chart's `values.yaml` says within seconds.

## 13.7 Try it

```sh
kubectl exec -n argocd deploy/argocd-repo-server -c ksops -- kustomize version
kubectl exec -n argocd deploy/argocd-repo-server -c ksops -- ksops version
```

Both should print a version with no error, confirming the sidecar actually has both binaries before chapter 14 ever asks it to render a real app.
