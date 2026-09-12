# 11. Kustomize inflating a Helm chart

`charts/` says what a workload *is*. `apps/` is where that gets pointed at a specific namespace and, from chapter 12 on, handed its secrets. This chapter builds the mechanism connecting the two, using Postgres as the example since chapter 12's secret is kept separate on purpose, so this chapter's one new idea isn't tangled up with another one at the same time.

## 11.1 Why not just `helm install` directly

Nothing stops you from having ArgoCD point straight at `charts/postgres` with a Helm source. The reason not to: chapter 12's ksops secret has to be generated and merged into the *same* rendered output as the chart, so a Secret and a StatefulSet referencing it show up together, atomically, in one ArgoCD `Application`. Kustomize is the tool that composes "inflate this Helm chart" with "run this other generator" into one output; ArgoCD's native Helm support alone can't add a generator step next to it.

## 11.2 A first attempt, and the error it produces on purpose

```sh
mkdir -p apps/platform/postgres
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
    valuesFile: ../../../charts/postgres/values.yaml
EOF

kustomize build --enable-helm apps/platform/postgres
```

This fails:

```
Error: security; file '/…/charts/postgres/values.yaml' is not in or below '/…/apps/platform/postgres'
```

Kustomize's default *load restrictor* refuses to read a file from outside the directory tree rooted at the `kustomization.yaml` itself. `valuesFile: ../../../charts/postgres/values.yaml` does exactly that on purpose — `apps/` and `charts/` are siblings, not one nested in the other — so this restriction has to be turned off for this repo's layout to work at all:

```sh
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/platform/postgres
```

This now renders Postgres's `ConfigMap`, `Service`, and `StatefulSet`, in the `platform` namespace, exactly as chapter 9 wrote them. **This flag is not optional and not specific to Postgres** — every `apps/*` overlay in this repo has the same `../../..`-climbing `valuesFile:`, so this exact error and fix apply to all of them. Chapter 13 bakes this flag into the one place it needs to live permanently (the ArgoCD plugin config), so it is never typed by hand again after this chapter.

## 11.3 How the local-chart inflation resolves

Two fields do the work:

* `helmGlobals.chartHome: ../../../charts` — the parent directory kustomize looks in.
* `helmCharts[].name: postgres` — kustomize looks for `<chartHome>/<name>`, i.e. `../../../charts/postgres`, and finds a real chart directory there. No `repo:` field is given, which is what tells kustomize this is a **local** chart, don't try to `helm pull` anything.

`releaseName: postgres` and `namespace: platform` are handed to `helm template` under the hood exactly like `helm install postgres charts/postgres -n platform` would. `valuesFile:` layers on top of the chart's own `values.yaml` the same way chapter 9.3's `-f values-prod.yaml` did.

Namespace appears twice on purpose: once at the top of `kustomization.yaml` (a Kustomize-level transformer stamping `namespace: platform` onto every object in the final output), and once inside the `helmCharts` entry (passed to Helm's own templating as `.Release.Namespace`). Chapter 9's charts don't reference `.Release.Namespace` directly, so only the top-level one does real work here — set in both places anyway since a future chart might.

## 11.4 Repeat for miniflux, redis, kafka, minio

```sh
mkdir -p apps/miniflux apps/platform/redis apps/platform/kafka apps/platform/minio
```

`apps/miniflux/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: miniflux

helmGlobals:
  chartHome: ../../charts

helmCharts:
  - name: miniflux
    releaseName: miniflux
    namespace: miniflux
    valuesFile: ../../charts/miniflux/values.yaml
```

`apps/platform/redis/kustomization.yaml`, `apps/platform/kafka/kustomization.yaml`, `apps/platform/minio/kustomization.yaml` follow chapter 11.2's exact shape, only `name`/`releaseName`/`valuesFile` change. Write these three yourself before continuing, the repetition is what makes this shape automatic.

## 11.5 Try it

```sh
for app in miniflux platform/postgres platform/redis platform/kafka platform/minio; do
  echo "=== $app ==="
  kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/$app | grep -E "^kind:|namespace:"
done
```

Confirm all five print the right namespace on every namespaced object, and that the `kind:` lines match what chapter 9 actually defined for each chart. None of these are meant to be `kubectl apply`-ed yet, their app-specific Secrets don't exist until chapter 12.
