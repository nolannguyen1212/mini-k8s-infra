# 3. The first real objects, by hand

One real app — [Miniflux](https://miniflux.app), an RSS reader, official public image `miniflux/miniflux` — backed by one real Postgres instance. Both by hand, raw YAML, no Helm yet (chapter 4 charts these same objects). This is the concrete implementation of everything that follows: a `Secret` mounted as env vars, a `StatefulSet` for the one workload that actually needs stable per-replica storage, a headless `Service` for its DNS, and an `Ingress` to reach Miniflux from outside the cluster.

Each app gets its own directory under `k8s/`, with its own `Namespace` object living right alongside its other manifests, and its own `kustomization.yaml` listing them — this is what turns five-plus individual `kubectl apply -f` calls into one `kubectl apply -k`. No Helm chart, no chart-inflation involved yet — `resources:` here is Kustomize's plainest feature, just "apply this list of files together."

## 3.1 Postgres

```sh
mkdir -p k8s/platform/postgres
```

`k8s/platform/postgres/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: platform
```

`k8s/platform/postgres/secret.yaml` — plaintext for now, on purpose: chapter 6 (Vault) replaces this exact file with something that never has a plaintext value sitting in git or on disk, but seeing the plain version first is what makes the problem it solves concrete instead of abstract:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: platform
type: Opaque
stringData:
  POSTGRES_PASSWORD: dev-superuser-password
  MINIFLUX_DB_PASSWORD: dev-miniflux-db-password
```

A `Secret`'s `data`/`stringData` is base64, not encrypted — anyone who can read this object (or this file, or git history) has the credential in cleartext. That's the entire reason chapter 6 exists.

`k8s/platform/postgres/configmap.yaml` — a `ConfigMap` mounted as a directory of files inside the container (`/docker-entrypoint-initdb.d`, the Postgres image's own convention for first-boot init scripts), rather than a single env var. The password itself is read from an environment variable (from the `Secret` above via `envFrom`) and handed to `psql` as a bind variable, never spliced into the SQL text itself. `CREATE ROLE ... IF NOT EXISTS` doesn't exist in Postgres, and a `DO $$ ... $$` PL/pgSQL block is one way around that — but the simpler, dependency-free way is generating the `CREATE ROLE` statement itself as text and only running it conditionally, via `\gexec`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: platform
data:
  miniflux-role.sh: |
    #!/bin/sh
    set -e
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -v rolepass="$MINIFLUX_DB_PASSWORD" <<-'EOSQL'
    SELECT format('CREATE ROLE miniflux LOGIN PASSWORD %L', :'rolepass')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'miniflux')\gexec
    SELECT 'CREATE DATABASE miniflux OWNER miniflux'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'miniflux')\gexec
    REVOKE ALL ON DATABASE miniflux FROM PUBLIC;
    EOSQL
```

Read the two `\gexec` lines as one unit each: `SELECT format(...) WHERE NOT EXISTS (...)` produces either zero rows (role/database already exists, nothing to do) or exactly one row containing a ready-to-run `CREATE ROLE`/`CREATE DATABASE` statement as text; `\gexec` then executes whatever text that query just returned, or executes nothing at all if it returned no rows. `format('...%L', :'rolepass')` is what safely quotes the password into that generated statement — `%L` is `format()`'s own "quote this as a SQL literal" verb, doing for the *generated* statement what `:'rolepass'` already does for the *outer* one. `<<-'EOSQL'` (a **quoted** heredoc delimiter) disables all shell expansion inside the block, so none of this SQL punctuation is touched by the shell before `psql` ever sees it.

`k8s/platform/postgres/statefulset.yaml`. A `StatefulSet` (not a `Deployment`) because Postgres needs two things a `Deployment` doesn't give: a stable identity (`postgres-0`, always the same name across restarts) and its own dedicated storage that reattaches to that same identity on every restart — a `Deployment`'s Pods are interchangeable by design, which is wrong for a database:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: platform
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_USER
              value: postgres
          envFrom:
            - secretRef: { name: postgres-secret }
          volumeMounts:
            # subPath avoids a real gotcha: some dynamic PV backends put a
            # lost+found dir at the volume root, and postgres refuses to
            # initdb into a non-empty data directory.
            - { name: data, mountPath: /var/lib/postgresql/data, subPath: pgdata }
            - { name: init, mountPath: /docker-entrypoint-initdb.d }
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits:   { cpu: 1, memory: 1Gi }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: init
          configMap:
            name: postgres-init
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 5Gi } }
```

`volumeClaimTemplates` is the StatefulSet-specific mechanism: unlike a `Deployment`'s shared `volumes:`, each replica gets its **own** `PersistentVolumeClaim` (`data-postgres-0`, `data-postgres-1`, ...), created once and reattached to the same Pod identity on every restart — the actual reason a database needs a StatefulSet at all.

`k8s/platform/postgres/service.yaml` — headless (`clusterIP: None`): a normal `Service` load-balances across replicas and hides which specific Pod you hit, which is wrong for a StatefulSet where identity matters. A headless `Service` instead gives DNS a distinct name per Pod (`postgres-0.postgres.platform.svc.cluster.local`), which is what a StatefulSet needs to be addressable at all:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: platform
spec:
  clusterIP: None
  selector: { app: postgres }
  ports:
    - port: 5432
```

`k8s/platform/postgres/networkpolicy.yaml` — by default every Pod in the cluster can reach every other Pod; this scopes Postgres down to accepting connections from the `miniflux` namespace only, nothing else:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-allow-from-miniflux
  namespace: platform
spec:
  podSelector:
    matchLabels: { app: postgres }
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: miniflux }
      ports:
        - port: 5432
```

Note kind's default CNI (kindnet) does **not** enforce `NetworkPolicy` — this object is correct, but on a stock kind cluster it applies without error yet blocks nothing. Worth knowing before assuming a local test proves more than it does — a CNI that actually enforces `NetworkPolicy` would genuinely block the traffic this object describes; kind's doesn't.

`k8s/platform/postgres/kustomization.yaml` — the file that turns the five objects above into one `kubectl apply -k`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.yaml
  - configmap.yaml
  - service.yaml
  - statefulset.yaml
  - networkpolicy.yaml
```

```sh
kubectl apply -k k8s/platform/postgres
kubectl rollout status statefulset/postgres -n platform
kubectl get pvc -n platform                                   # data-postgres-0, Bound
kubectl exec -it postgres-0 -n platform -- psql -U postgres -c '\l'   # confirm the "miniflux" database exists
```

## 3.2 Miniflux

```sh
mkdir -p k8s/miniflux
```

`k8s/miniflux/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: miniflux
```

`k8s/miniflux/secret.yaml` — same plaintext-for-now caveat as 3.1. Note the password inside `DATABASE_URL` has to be the exact same value as `postgres-secret`'s `MINIFLUX_DB_PASSWORD` above, since they authenticate the same role. Chapter 6.4 explains how Vault removes the need to keep two separate copies of this value in sync at all:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: miniflux-secret
  namespace: miniflux
type: Opaque
stringData:
  DATABASE_URL: "postgres://miniflux:dev-miniflux-db-password@postgres.platform.svc.cluster.local:5432/miniflux?sslmode=disable"
  ADMIN_USERNAME: admin
  ADMIN_PASSWORD: dev-admin-password
```

`k8s/miniflux/deployment.yaml` — a plain `Deployment` this time: Miniflux is stateless (all its state is in Postgres), so replicas are fully interchangeable, no stable identity or per-replica storage needed. `RUN_MIGRATIONS=1` and `CREATE_ADMIN=1` tell Miniflux to run its own schema migrations and bootstrap the admin account on every start — both are idempotent, safe to leave set permanently:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: miniflux
  namespace: miniflux
spec:
  replicas: 1
  selector:
    matchLabels: { app: miniflux }
  template:
    metadata:
      labels: { app: miniflux }
    spec:
      containers:
        - name: miniflux
          image: miniflux/miniflux:latest
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - { name: RUN_MIGRATIONS, value: "1" }
            - { name: CREATE_ADMIN, value: "1" }
          envFrom:
            - secretRef: { name: miniflux-secret }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 250m, memory: 128Mi }
          readinessProbe:
            httpGet: { path: /healthcheck, port: 8080 }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /healthcheck, port: 8080 }
            initialDelaySeconds: 15
            periodSeconds: 15
```

If `/healthcheck` doesn't match Miniflux's actual current health endpoint by the time you're reading this, check the running container's logs on first boot and fix the one path, nothing else about this Deployment changes — the same caveat applies to any specific path/env-var name for a public image you didn't write: trust the image's own docs and logs over any page describing it, this one included.

`k8s/miniflux/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: miniflux
  namespace: miniflux
spec:
  selector: { app: miniflux }
  ports:
    - { port: 80, targetPort: 8080 }
```

`k8s/miniflux/ingress.yaml` — `miniflux.local` already resolves to your host via chapter 1.3's `/etc/hosts` line and ingress-nginx is already installed:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: miniflux
  namespace: miniflux
spec:
  ingressClassName: nginx
  rules:
    - host: miniflux.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: miniflux, port: { number: 80 } }
```

`k8s/miniflux/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

```sh
kubectl apply -k k8s/miniflux
kubectl rollout status deployment/miniflux -n miniflux
```

## 3.3 Verify end to end

```sh
curl http://miniflux.local/healthcheck

kubectl exec deploy/miniflux -n miniflux -- printenv | grep DATABASE_URL   # confirm it points at postgres.platform.svc.cluster.local
```

Log into Miniflux at `http://miniflux.local` in a browser with the `ADMIN_USERNAME`/`ADMIN_PASSWORD` from 3.2, confirming the whole chain actually works, not just that the Pods are `Running`.

```sh
# PVC survives a Pod restart, the entire point of a StatefulSet over a Deployment
kubectl delete pod postgres-0 -n platform
kubectl wait --for=condition=Ready pod/postgres-0 -n platform --timeout=60s
kubectl exec -it postgres-0 -n platform -- psql -U postgres -c '\l'   # miniflux database still there, same PVC reattached
curl http://miniflux.local/healthcheck    # still fine, miniflux's own connection recovers
```

## 3.4 Cleanup

```sh
kubectl delete -k k8s/miniflux
kubectl delete -k k8s/platform/postgres
```

`kubectl delete statefulset` does not delete its PVC by default — this is deliberate (StatefulSet storage outlives the workload on purpose). Delete it explicitly if you actually want the data gone:

```sh
kubectl delete pvc data-postgres-0 -n platform
```
