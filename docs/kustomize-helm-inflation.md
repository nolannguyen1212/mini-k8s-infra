# 5. Kustomize inflating a Helm chart

`charts/` says what a workload *is*. `apps/` (chapter 2.1's skeleton) is where that gets pointed at a specific namespace and specific values. This chapter builds the mechanism connecting the two, using Postgres as the example.

## 5.1 Why not just `helm install` directly

Nothing stops you from having ArgoCD point straight at `charts/postgres` with a Helm source, and for a single chart with no other moving parts that's a reasonable choice. The reason this repo uses Kustomize instead: it gives every app a single, uniform overlay shape (`apps/<name>/kustomization.yaml`) regardless of what that app needs beyond "inflate a chart" — a values override today, potentially a patch or a second generator later — without ArgoCD's `Application` object needing to know which kind of app it's looking at. One consistent rendering path, `kustomize build --enable-helm`, for everything in `apps/`.

## 5.2 apps/platform/postgres/kustomization.yaml

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

This renders Postgres's `ConfigMap`, `Service`, and `StatefulSet` in the `platform` namespace, exactly as chapter 4 wrote them. **The flag applies to every `apps/*` overlay in this repo**, not just Postgres — all of them share the same `../../..`-climbing `chartHome`. Chapter 7 bakes it into the one place it needs to live permanently (ArgoCD's own kustomize build options), so it's never typed by hand again after this chapter.

## 5.3 How the local-chart inflation resolves

Two fields do the work:

* `helmGlobals.chartHome: ../../../charts` — the parent directory kustomize looks in.
* `helmCharts[].name: postgres` — kustomize looks for `<chartHome>/<name>`, i.e. `../../../charts/postgres`, and finds a real chart directory there. No `repo:` field is given, which is what tells kustomize this is a **local** chart, don't try to `helm pull` anything.

`releaseName: postgres` and `namespace: platform` are handed to `helm template` under the hood exactly like `helm install postgres charts/postgres -n platform` would. No `valuesFile:` here — with none given, kustomize renders using only the chart's own bundled `values.yaml`, same as `helm template` with no `-f` at all. A `valuesFile: ../../../charts/postgres/values-prod.yaml` entry would layer a genuinely different, environment-specific file on top (chapter 4.3's `-f` flag, expressed here instead) — worth adding the day a second environment overlay actually needs one, not before.

Namespace appears twice on purpose: once at the top of `kustomization.yaml` (a Kustomize-level transformer stamping `namespace: platform` onto every object in the final output), and once inside the `helmCharts` entry (passed to Helm's own templating as `.Release.Namespace`). Chapter 4's charts don't reference `.Release.Namespace` directly, so only the top-level one does real work here — set in both places anyway since a future chart might.

## 5.4 Repeat for Miniflux

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

Same shape as 5.2, only `name`/`releaseName`/the chart-home relative depth change (`apps/miniflux` is one level shallower than `apps/platform/postgres`).

## 5.5 Try it

```sh
for app in miniflux platform/postgres; do
  echo "=== $app ==="
  kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/$app | grep -E "^kind:|namespace:"
done
```

Confirm both print the right namespace on every namespaced object, and that the `kind:` lines match what chapter 4 actually defined for each chart. Neither is meant to be `kubectl apply`-ed yet — both charts still reference a `Secret` (`postgres-secret`, `miniflux-secret`) that only exists as chapter 3's plaintext, hand-applied object. Chapter 6 replaces that with Vault, chapter 8 wires the result into these two overlays for real.
