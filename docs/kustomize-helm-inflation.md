# Kustomize inflating a Helm chart

- `charts/` says what a workload *is*
- `apps/` ([The full repo, decided up front](gitops-repo-layout.md#the-full-repo-decided-up-front)'s skeleton) is where that gets pointed at a specific namespace and specific values
- This chapter builds the mechanism connecting the two, using Postgres as the example

## Why not just `helm install` directly

Nothing stops you from having ArgoCD point straight at `charts/postgres` with a Helm source, and for a single chart with no other moving parts that's a reasonable choice. The reason this repo uses Kustomize instead: it gives every app a single, uniform overlay shape (`apps/<name>/kustomization.yaml`) regardless of what that app needs beyond "inflate a chart" (a values override today, potentially a patch or a second generator later) without ArgoCD's `Application` object needing to know which kind of app it's looking at. One consistent rendering path, `kustomize build --enable-helm`, for everything in `apps/`.

## apps/platform/postgres/kustomization.yaml

```sh
cat > apps/platform/postgres/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: platform

helmGlobals:
  chartHome: ../../../charts

helmCharts:
  - name: postgres
    releaseName: postgres
    namespace: platform
EOF

kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/platform/postgres
```

`--load-restrictor LoadRestrictionsNone` is required: kustomize's default load restrictor refuses to read any file from outside the directory tree rooted at `kustomization.yaml` itself, and `helmGlobals.chartHome: ../../../charts` does exactly that on purpose, since `apps/` and `charts/` are siblings, not one nested in the other. Rendering a local chart at all means reading its `Chart.yaml`/`templates/`/`values.yaml` from outside this directory, so the flag isn't optional for this repo's layout.

This renders Postgres's `ConfigMap`, `Service`, and `StatefulSet` in the `platform` namespace, exactly as [Helm: charting Postgres and Miniflux](helm-charts.md) wrote them. **The flag applies to every `apps/*` overlay in this repo**, not just Postgres: all of them share the same `../../..`-climbing `chartHome`. [ArgoCD: git becomes the source of truth](argocd.md) bakes it into the one place it needs to live permanently (ArgoCD's own kustomize build options), so it's never typed by hand again after this chapter.

## How the local-chart inflation resolves

Two fields do the work:

* `helmGlobals.chartHome: ../../../charts`: the parent directory kustomize looks in.
* `helmCharts[].name: postgres`: kustomize looks for `<chartHome>/<name>`, i.e. `../../../charts/postgres`, and finds a real chart directory there. No `repo:` field is given, which is what tells kustomize this is a **local** chart, don't try to `helm pull` anything.

`releaseName: postgres` and `namespace: platform` are handed to `helm template` under the hood exactly like `helm install postgres charts/postgres -n platform` would. No `valuesFile:` here: with none given, kustomize renders using only the chart's own bundled `values.yaml`, same as `helm template` with no `-f` at all. A `valuesFile: ../../../charts/postgres/values-prod.yaml` entry would layer a genuinely different, environment-specific file on top ([Per-environment values, and the render/diff/install loop](helm-charts.md#per-environment-values-and-the-renderdiffinstall-loop)'s `-f` flag, expressed here instead), worth adding the day a second environment overlay actually needs one, not before.

Namespace appears twice on purpose: once at the top of `kustomization.yaml` (a Kustomize-level transformer stamping `namespace: platform` onto every object in the final output), and once inside the `helmCharts` entry (passed to Helm's own templating as `.Release.Namespace`). [Helm: charting Postgres and Miniflux](helm-charts.md)'s charts don't reference `.Release.Namespace` directly, so only the top-level one does real work here: set in both places anyway since a future chart might.

## Repeat for Miniflux

```sh
cat > apps/miniflux/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: miniflux

helmGlobals:
  chartHome: ../../charts

helmCharts:
  - name: miniflux
    releaseName: miniflux
    namespace: miniflux
EOF
```

Same shape as [apps/platform/postgres/kustomization.yaml](#appsplatformpostgreskustomizationyaml) above, only `name`/`releaseName`/the chart-home relative depth change (`apps/miniflux` is one level shallower than `apps/platform/postgres`).

## Try it

```sh
for app in miniflux platform/postgres; do
  echo "=== $app ==="
  kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/$app | grep -E "^kind:|namespace:"
done
```

Confirm both print the right namespace on every namespaced object, and that the `kind:` lines match what [Helm: charting Postgres and Miniflux](helm-charts.md) actually defined for each chart. Neither is meant to be `kubectl apply`-ed yet: both charts still reference a `Secret` (`postgres-secret`, `miniflux-secret`) that only exists as [The first real objects, by hand](first-objects-by-hand.md)'s plaintext, hand-applied object. [Vault: secrets as a live service, not a file in git](vault-secrets.md) replaces that with Vault, [Miniflux, end to end](miniflux-deployment.md) wires the result into these two overlays for real.
