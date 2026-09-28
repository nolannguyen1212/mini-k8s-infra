# Observability: watching what's actually running

- [Miniflux, end to end](miniflux-deployment.md) turned on `METRICS_COLLECTOR=1`, but nothing has ever read that endpoint
- Until now, the only tools for "is this healthy" have been `kubectl logs`, `kubectl describe`, and the readiness/liveness probes: no CPU/memory history, no request-rate or error-rate numbers, nothing that survives past `kubectl logs --previous`
- This chapter installs `metrics-server` for basic resource numbers, then Prometheus + Grafana (via the `kube-prometheus-stack` Helm chart) to scrape and graph Miniflux's own `/metrics`
- It goes on to instrument Postgres too, centralize logs with Loki, and turn one Prometheus rule into an actual notification, not just metrics sitting in a dashboard nobody's watching

## The pipeline, end to end

<img src="img/observability-pipeline.svg" alt="Application workloads cluster (Miniflux, Postgres + postgres_exporter) is scraped through a ServiceMonitor inside the Kubernetes cluster, which tells the Prometheus Operator where to scrape inside the kube-prometheus-stack cluster. Prometheus is queried by Grafana over PromQL, and its rules feed Alertmanager, which sends notifications to a webhook receiver. Separately, the kubelet inside the Kubernetes cluster feeds a Log pipeline cluster: a Promtail DaemonSet tails container logs, ships them to Loki, which Grafana queries over LogQL." width="480">

Two independent lanes, built up separately below: metrics (left) needed Miniflux and Postgres to expose something scrapeable first; logs (right) needed nothing from either app, since the kubelet writes every container's stdout/stderr regardless. Both lanes end up queried from the same Grafana, through two different query languages against two different datasources.

## metrics-server: making `kubectl top` real

Every `kubectl top` command so far would have failed silently with "Metrics API not available": nothing collects resource metrics by default, kind included.

```sh
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

This fails to ever go `Ready` on kind specifically: `metrics-server` verifies the kubelet's TLS certificate by default, and kind's kubelet certs aren't signed for that. Patch the one flag that disables that check, acceptable on a local lab, not something to carry into a real cluster:

```sh
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
kubectl rollout status deployment/metrics-server -n kube-system
```

```sh
kubectl top nodes
kubectl top pods -n miniflux
```

If either command still errors after a `Ready` rollout, give it another 30-60 seconds: `metrics-server` needs at least one full scrape cycle before it has anything to report.

## Install kube-prometheus-stack

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring
```

One `helm install` here brings in five separate things, worth naming since each shows up as its own set of Pods: the Prometheus Operator (turns `ServiceMonitor`/`Prometheus` into actual scrape config), Prometheus itself (run as a `Prometheus` custom resource, not a plain `Deployment`), Alertmanager, Grafana, and two DaemonSet/Deployment exporters (`node-exporter` for host-level metrics, `kube-state-metrics` for Kubernetes object state). This is meaningfully heavier than anything installed on this cluster so far: give kind's Docker VM a few minutes and, if Pods sit `Pending`, more memory before assuming something's wrong.

```sh
kubectl get pods -n monitoring
```

## Turn on Miniflux's own metrics, and name the Service port

`METRICS_COLLECTOR=1` is already set from [Miniflux's own configuration surface](miniflux-deployment.md#minifluxs-own-configuration-surface), so the container is already serving `/metrics`. Two things still block Prometheus from reaching it.

First, Miniflux's own metrics endpoint defaults to a localhost-only allowlist, since it assumes whatever scrapes it runs in the same Pod. Prometheus runs in a different Pod entirely, so this has to be widened. Add to `charts/miniflux/values.yaml`:

```yaml
env:
  METRICS_ALLOWED_NETWORKS: "0.0.0.0/0"
```

Fine for a local lab where the whole cluster is trusted; a real deployment would scope this to the cluster's actual Pod CIDR instead of opening it to everything. Verify the exact env var name against Miniflux's own README before trusting it on a version far from what this was written against, same caveat as the `/healthcheck` path.

Second, `charts/miniflux/templates/service.yaml`'s port has no name, and a `ServiceMonitor` selects a port by name, not by number:

```yaml
  ports:
    - { name: http, port: 80, targetPort: 8080 }
```

```sh
helm upgrade --install miniflux charts/miniflux -n miniflux
```

## ServiceMonitor: telling Prometheus where to scrape

`charts/miniflux/templates/servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ .Release.Name }}
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels: { app: {{ .Release.Name }} }
  namespaceSelector:
    matchNames: ["miniflux"]
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

The `release: kube-prometheus-stack` label is not decoration: this chart's Prometheus, by default, only watches `ServiceMonitor` objects carrying a `release` label matching the Helm release name it was installed under. Skip it and the object applies cleanly, shows up in `kubectl get servicemonitor`, and Prometheus silently never scrapes it: the single most common way people lose an afternoon to this chart.

```sh
helm upgrade --install miniflux charts/miniflux -n miniflux
kubectl get servicemonitor -n miniflux
```

Confirm Prometheus actually picked it up, rather than trusting the object exists:

```sh
kubectl port-forward svc/kube-prometheus-stack-kube-prome-prometheus -n monitoring 9090:9090
```

Open `http://localhost:9090/targets`: `miniflux/miniflux` should show as `UP`. If the Service name here doesn't match what `helm install` actually created, run `kubectl get svc -n monitoring` and use the real name: this chart's generated names have shifted across versions before.

## Grafana: look at the numbers, not just the dashboard

```sh
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
```

Log into `http://localhost:3000` as `admin` with that password. Before building or trusting any dashboard, curl the raw endpoint once, the same "trust the source over the abstraction" habit as reading `helm template` output before applying it:

```sh
kubectl exec -it deploy/miniflux -n miniflux -- wget -qO- http://localhost:8080/metrics | grep -i miniflux | head -20
```

Whatever metric names print here (not whatever a dashboard elsewhere claims Miniflux exposes) are what to actually query in Grafana's Explore view against the `Prometheus` datasource, which this chart wires up automatically.

## Instrument Postgres too

Miniflux exposes its own metrics because the application chose to. Postgres's own image never does that: nothing in `postgres:16-alpine` speaks Prometheus's format. The standard fix is `postgres_exporter`, run as a sidecar in the same Pod so it can reach Postgres over `localhost` without any new networking. `charts/postgres/templates/statefulset.yaml`, one more container in `spec.template.spec.containers`:

```yaml
        - name: postgres-exporter
          image: prometheuscommunity/postgres-exporter:v0.15.0   # pin a real tag before this matters for real
          command: ["sh", "-c"]
          args:
            - export DATA_SOURCE_NAME="postgresql://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres?sslmode=disable" && exec postgres_exporter
          envFrom:
            - secretRef: { name: postgres-secret }
          ports:
            - { name: metrics, containerPort: 9187 }
```

Same `command`/`args` shape as [The Agent Injector annotations, and the templating-inside-templating gotcha](vault-secrets.md#the-agent-injector-annotations-and-the-templating-inside-templating-gotcha)'s reason for existing: the exporter binary only reads `DATA_SOURCE_NAME` as a real env var, so it has to be composed from the existing `POSTGRES_PASSWORD` at container start, not baked into the image. `charts/postgres/templates/service.yaml` needs the new port named and exposed:

```yaml
  ports:
    - { port: 5432 }
    - { name: metrics, port: 9187 }
```

`charts/postgres/templates/servicemonitor.yaml`, the same shape as Miniflux's, same `release:` label requirement:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ .Release.Name }}
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels: { app: {{ .Release.Name }} }
  namespaceSelector:
    matchNames: ["platform"]
  endpoints:
    - port: metrics
      interval: 30s
```

```sh
helm upgrade --install postgres charts/postgres -n platform
kubectl get pod postgres-0 -n platform     # now 2/2, postgres + postgres-exporter
```

## Centralized logs with Loki and Promtail

Metrics needed Miniflux's own cooperation (it had to choose to expose `/metrics`); logs don't; the kubelet already writes every container's stdout/stderr to disk on every node regardless of what the app does. Promtail just tails those files and ships them to Loki, Loki's own storage/query engine:

```sh
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki-stack -n monitoring --set grafana.enabled=false
```

`grafana.enabled=false` matters: `loki-stack` bundles its own Grafana by default, and there's already one running from `kube-prometheus-stack`. Two Grafanas fighting over the same job is pure confusion, not redundancy.

This Grafana has no idea Loki exists yet: `kube-prometheus-stack` auto-provisioned the Prometheus datasource because it owns both halves; Loki is a completely separate Helm release, so the connection has to be made by hand. In Grafana: **Connections → Data sources → Add data source → Loki**, URL `http://loki:3100` (the Service name defaults to the Helm release name), **Save & test**.

```sh
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail   # one Pod per node, a DaemonSet
```

## Alerting: from a fired rule to a real notification

Alertmanager has been running since [Install kube-prometheus-stack](#install-kube-prometheus-stack) with nothing to do: no rule has ever fired, and nothing is configured to receive one. A rule first. `PrometheusRule` objects need the same `release:` label as `ServiceMonitor` for the same reason, so apply this directly rather than routing it through either chart:

```sh
cat > /tmp/miniflux-alerts.yaml <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: miniflux-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: miniflux
      rules:
        - alert: MinifluxPodRestarting
          expr: increase(kube_pod_container_status_restarts_total{namespace="miniflux"}[15m]) > 0
          for: 1m
          labels: { severity: warning }
          annotations:
            summary: "Miniflux Pod restarted in the last 15 minutes"
EOF
kubectl apply -f /tmp/miniflux-alerts.yaml
```

`kube_pod_container_status_restarts_total` comes from `kube-state-metrics`, already scraped by default: no new `ServiceMonitor` needed for a rule that only reads Kubernetes object state rather than an app's own metrics.

A rule with nowhere to send its alert is still just a rule. For a local lab, a disposable echo server proves the wiring without needing a real Slack workspace or email account:

```sh
kubectl create namespace webhook-test --dry-run=client -o yaml | kubectl apply -f -
kubectl run echo --image=mendhak/http-https-echo -n webhook-test --port=8080
kubectl expose pod echo -n webhook-test --port=80 --target-port=8080
```

```sh
cat > /tmp/alertmanager-values.yaml <<'EOF'
alertmanager:
  config:
    route:
      receiver: webhook-test
    receivers:
      - name: webhook-test
        webhook_configs:
          - url: http://echo.webhook-test.svc.cluster.local/
EOF
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring \
  --reuse-values -f /tmp/alertmanager-values.yaml
```

`--reuse-values` matters here: without it, this `upgrade` would silently reset every other value (Grafana's password, retention settings, everything) back to the chart's defaults, since a bare `-f` only merges the one file given, not the running release's actual state.

Trigger the rule for real, rather than trusting the YAML:

```sh
kubectl exec deploy/miniflux -n miniflux -c miniflux -- kill 1
kubectl logs -n webhook-test -l run=echo --tail=50   # the alert payload should land within ~2 minutes
```

`kill 1` kills the container's own PID 1 in place, which the kubelet counts as a crash and restarts, incrementing the same restart counter the rule watches; deleting the Pod outright would just create a fresh Pod with its restart count reset to zero instead.

## Wiring this into ArgoCD later

`kube-prometheus-stack` was installed by hand in this chapter for the same reason Vault and ArgoCD itself were: something has to exist before a GitOps controller can manage anything, so the very first install of any platform tool is always manual. Once [ArgoCD: git becomes the source of truth](argocd.md) is actually applied to this cluster, ongoing lifecycle (values changes, chart upgrades) can move to git, one structural difference from Postgres/Miniflux's `Application`s: this is an upstream chart pulled straight from a Helm repo, not a local chart under `charts/`, so it skips [Kustomize inflating a Helm chart](kustomize-helm-inflation.md)'s inflation path entirely and points `source` at the Helm repo directly:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: "<pin an exact chart version here>"
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

Not applied in this chapter: it depends on ArgoCD actually being bootstrapped first, which this repo hasn't done yet.

## Try it

1. In Grafana's Explore view, graph one Miniflux counter over time. Add a feed through the UI, refresh the graph, and confirm the number moves: proof the metric is real, not that a dashboard merely renders without erroring.
2. Repeat [Prove the failure modes, not just the happy path](miniflux-deployment.md#prove-the-failure-modes-not-just-the-happy-path)'s Postgres-restart drill while watching Grafana's default "Kubernetes / Compute Resources / Namespace (Pods)" dashboard for the `platform` namespace: the restart should be visible as a CPU/memory dip and a Pod restart count increment, not just something you infer from `kubectl get pods`.
3. In Grafana's Explore view against the Loki datasource, query `{namespace="miniflux"}` while adding another feed through the UI. Confirm the same log lines `kubectl logs` would show turn up here too, retroactively searchable instead of tied to one Pod's own buffer.
4. Query `pg_up` (from `postgres_exporter`) in Explore, then run [Prove the failure modes, not just the happy path](miniflux-deployment.md#prove-the-failure-modes-not-just-the-happy-path)'s Postgres-restart drill again: watch the metric actually drop to `0` and recover, not just infer it from the Pod's status column.
5. `helm uninstall kube-prometheus-stack -n monitoring`, then reinstall it. Confirm the `ServiceMonitor`s for Miniflux and Postgres, and their scraping, resume without being recreated: they're git-managed chart templates, not state that lived inside Prometheus itself, the same lesson [GitOps and the repo layout](gitops-repo-layout.md) made about git being the source of truth, now for observability config too.
