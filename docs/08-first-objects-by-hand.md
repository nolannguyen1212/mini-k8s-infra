# 8. The first real objects, by hand

One real app — [Miniflux](https://miniflux.app), an RSS reader, official public image `miniflux/miniflux` — backed by one real Postgres instance. Both by hand, raw YAML, no Helm yet (chapter 9 charts these same objects). This is the concrete implementation of chapter 5's file-mount-vs-env-var split, chapter 2's StatefulSet, and chapter 3's cross-namespace NetworkPolicy, on the actual thing this repo hosts, not a throwaway example.

Postgres and Miniflux live in separate namespaces on purpose from the start: `platform` for anything meant to be shared by more than one app later, `miniflux` for this one app's own objects. Chapter 3.5's NetworkPolicy already assumed this split.

## 8.1 Namespaces

```sh
kubectl create namespace platform
kubectl create namespace miniflux
```

## 8.2 Postgres

```sh
mkdir -p k8s/platform
```

`k8s/platform/postgres-secret.yaml` — plaintext for now, on purpose: chapter 10 replaces this exact file with something that never has a plaintext value sitting in git, but seeing the plain version first is what makes the problem it solves concrete instead of abstract:

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

`k8s/platform/postgres-init.yaml` — chapter 5.5's ConfigMap-as-mounted-directory pattern, for real. The password is read from an environment variable (from the Secret above via `envFrom`) and handed to `psql` as a bind variable, never spliced into the SQL text itself:

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
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'miniflux') THEN
        CREATE ROLE miniflux WITH LOGIN PASSWORD :'rolepass';
      END IF;
    END
    $$;
    SELECT 'CREATE DATABASE miniflux OWNER miniflux'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'miniflux')\gexec
    REVOKE ALL ON DATABASE miniflux FROM PUBLIC;
    EOSQL
```

`<<-'EOSQL'` (a **quoted** heredoc delimiter) disables all shell expansion inside the block, so Postgres's own `$$ ... $$` function-body syntax reaches `psql` untouched. `-v rolepass="$MINIFLUX_DB_PASSWORD"` hands the actual password to `psql` outside the heredoc; `:'rolepass'` inside it is `psql`'s own safe-quoting substitution. This is the difference between a password containing a `'` or `$` working correctly and silently breaking the script.

`k8s/platform/postgres-statefulset.yaml`:

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

`k8s/platform/postgres-service.yaml` — headless, chapter 3.2's rule (StatefulSet needs one for a stable per-Pod DNS name):

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

```sh
kubectl apply -f k8s/platform/postgres-secret.yaml
kubectl apply -f k8s/platform/postgres-init.yaml
kubectl apply -f k8s/platform/postgres-statefulset.yaml
kubectl apply -f k8s/platform/postgres-service.yaml
kubectl rollout status statefulset/postgres -n platform
kubectl get pvc -n platform                                   # data-postgres-0, Bound
kubectl exec -it postgres-0 -n platform -- psql -U postgres -c '\l'   # confirm the "miniflux" database exists
```

## 8.3 Miniflux

```sh
mkdir -p k8s/miniflux
```

`k8s/miniflux/miniflux-secret.yaml` — same plaintext-for-now caveat as 8.2. Note the password inside `DATABASE_URL` has to be the exact same value as `postgres-secret`'s `MINIFLUX_DB_PASSWORD` above, they authenticate the same role, chapter 17 explains what keeping these in sync actually looks like once they're both encrypted files instead of both plaintext in your terminal history:

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

`k8s/miniflux/miniflux-deployment.yaml`. `RUN_MIGRATIONS=1` and `CREATE_ADMIN=1` tell Miniflux to run its own schema migrations and bootstrap the admin account on every start — both are idempotent, safe to leave set permanently:

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

`k8s/miniflux/miniflux-service.yaml`:

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

`k8s/miniflux/miniflux-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: miniflux
  namespace: miniflux
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
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

```sh
kubectl apply -f k8s/miniflux/miniflux-secret.yaml
kubectl apply -f k8s/miniflux/miniflux-deployment.yaml
kubectl apply -f k8s/miniflux/miniflux-service.yaml
kubectl apply -f k8s/miniflux/miniflux-ingress.yaml
kubectl rollout status deployment/miniflux -n miniflux
```

## 8.4 The NetworkPolicy, applied for real

Chapter 3.5 already wrote this exact object as an illustration. Apply it now, for real:

```sh
mkdir -p k8s/platform
cat > k8s/platform/postgres-networkpolicy.yaml <<'EOF'
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
EOF
kubectl apply -f k8s/platform/postgres-networkpolicy.yaml
```

Remember chapter 3.5's caveat: kind's default CNI (kindnet) does not enforce NetworkPolicy. This object is correct and is exactly what k3s's default CNI (chapter 15) does enforce, but on a stock kind cluster it applies without error yet blocks nothing — worth knowing before assuming a local isolation test proves more than it does.

## 8.5 Verify end to end

```sh
echo "127.0.0.1 miniflux.local" | sudo tee -a /etc/hosts   # if not already done in chapter 3
curl http://miniflux.local/healthcheck

kubectl exec deploy/miniflux -n miniflux -- printenv | grep DATABASE_URL   # confirm it points at postgres.platform.svc.cluster.local
```

Log into Miniflux at `http://miniflux.local` in a browser with the `ADMIN_USERNAME`/`ADMIN_PASSWORD` from 8.3, confirming the whole chain actually works, not just that the Pods are `Running`.

```sh
# PVC survives a Pod restart, the entire point of a StatefulSet over a Deployment
kubectl delete pod postgres-0 -n platform
kubectl wait --for=condition=Ready pod/postgres-0 -n platform --timeout=60s
kubectl exec -it postgres-0 -n platform -- psql -U postgres -c '\l'   # miniflux database still there, same PVC reattached
curl http://miniflux.local/healthcheck    # still fine, miniflux's own connection recovers
```

## 8.6 Cleanup

```sh
kubectl delete -f k8s/miniflux
kubectl delete -f k8s/platform
```

`kubectl delete statefulset` does not delete its PVC by default, this is deliberate (StatefulSet storage outlives the workload on purpose). Delete it explicitly if you actually want the data gone:

```sh
kubectl delete pvc data-postgres-0 -n platform
```
