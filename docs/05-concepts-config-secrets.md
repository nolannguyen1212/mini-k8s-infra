# 5. Config and secrets

## 5.1 The rule

Never bake environment-specific config into a container image. Build one image, run it in dev/staging/prod with different config injected at deploy time. Kubernetes gives two objects for this:

* **ConfigMap**: non-sensitive config (feature flags, URLs, log level, a full config file).
* **Secret**: sensitive config (passwords, tokens, keys). Mechanically almost identical to ConfigMap, values are just base64 encoded, not encrypted, at rest unless you enable encryption at the etcd level or encrypt the manifest itself before it ever reaches git (chapter 10). Treat Secret as "marked sensitive," not as "safe."

Both can reach a container in two ways: as **environment variables** or as a **mounted file**. This choice is the entire story behind why Postgres's own startup scripts arrive as mounted files while miniflux's database connection arrives as a plain environment variable, covered in 5.4 and 5.5.

## 5.2 ConfigMap

```sh
kubectl create configmap app-config --from-literal=LOG_LEVEL=debug --from-literal=FEATURE_X=on
kubectl get configmap app-config -o yaml
```

Declarative form:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: debug
  FEATURE_X: "on"
```

A ConfigMap can also hold one or more entire files as keys, this is the pattern chapter 8 uses for Postgres's own startup scripts:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
data:
  miniflux-role.sh: |
    #!/bin/sh
    set -e
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -v rolepass="$MINIFLUX_DB_PASSWORD" <<-'EOSQL'
    CREATE ROLE miniflux WITH LOGIN PASSWORD :'rolepass';
    EOSQL
```

Or generate it directly from a file, so the file itself stays the source of truth in your repo:

```sh
kubectl create configmap postgres-init --from-file=miniflux-role.sh
```

## 5.3 Secret

```sh
kubectl create secret generic app-secret \
  --from-literal=DB_PASSWORD=devpassword \
  --from-literal=API_KEY=abc123
kubectl get secret app-secret -o yaml     # values shown base64 encoded, not encrypted
kubectl get secret app-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

Declarative form, values must be base64:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
stringData:          # stringData accepts plain text, k8s encodes it for you on apply
  DB_PASSWORD: devpassword
  API_KEY: abc123
```

Never commit a rendered Secret (the `data:` base64 form) to git, base64 is encoding not encryption, anyone with the YAML has the plaintext. Chapter 10 exists specifically to solve "how do I GitOps a Secret without putting the plaintext in git."

Built-in Secret types worth knowing:

| type | purpose |
|------|---------|
| `Opaque` | generic key/value, the default |
| `kubernetes.io/dockerconfigjson` | credentials for pulling images from a private registry |
| `kubernetes.io/tls` | a TLS cert/key pair, consumed by Ingress for HTTPS |

## 5.4 Consuming as environment variables

Single key:

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: app-secret
        key: DB_PASSWORD
  - name: LOG_LEVEL
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: LOG_LEVEL
```

All keys at once, each key becomes one env var:

```yaml
envFrom:
  - configMapRef:
      name: app-config
  - secretRef:
      name: app-secret
```

This is exactly the `.env` mental model, a flat list of `KEY=value` pairs loaded into the process environment. It maps directly onto how a Node.js app reads `process.env.X` (typically via `dotenv` locally, and via real env vars in any container runtime, dotenv is a local dev convenience, in a Pod the container never reads a `.env` file, the values just already exist as real environment variables set by the kubelet before your process starts).

## 5.5 Consuming as a mounted file

```yaml
volumes:
  - name: init
    configMap:
      name: postgres-init
containers:
  - name: postgres
    volumeMounts:
      - name: init
        mountPath: /docker-entrypoint-initdb.d   # miniflux-role.sh appears here, one file per ConfigMap key
```

This is the pattern for anything that expects a real file on disk, not an environment variable, because the postgres image's own startup logic (not your code) looks for files in that exact directory. Every key in the ConfigMap becomes one file in the mounted directory, named after the key — a ConfigMap is not limited to one file per mount, chapter 9's real Postgres chart mounts several this way, one per database role it provisions.

Secrets mounted as files work identically, each key in the Secret becomes a file named after the key, containing the decoded value:

```yaml
volumes:
  - name: secret-files
    secret:
      secretName: app-secret
containers:
  - name: app
    volumeMounts:
      - name: secret-files
        mountPath: /etc/secrets
        readOnly: true
        # /etc/secrets/DB_PASSWORD contains the plaintext value
```

## 5.6 Why the split matters: mount vs env, and live updates

| | env var | mounted file |
|---|---|---|
| set once at container start | yes | yes, but see below |
| app must restart to pick up a change | always | ConfigMap/Secret volumes are updated in place by kubelet (polling, up to ~1 minute delay), env vars never update without a Pod restart |
| natural fit | flat key/value (.env style) | structured file, or something an image's own entrypoint script expects to find on disk |

Practical consequence for the two workloads chapter 8 builds:

* **postgres**: its startup scripts arrive as files mounted at `/docker-entrypoint-initdb.d`, because that is the exact mechanism the official postgres image looks for, not a choice this repo made. No amount of environment variables could substitute for it, the image's own entrypoint is what reads that directory.
* **miniflux**: its database connection string and admin credentials arrive as plain environment variables (`DATABASE_URL`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`) via `envFrom`, because that is what the miniflux binary itself reads at startup. Changing one requires the Pod to restart (`kubectl rollout restart deployment/miniflux`) because env vars are frozen at container start — chapter 8 shows this happening for real.

Neither choice is up to this repo, both are dictated by what the underlying image actually expects. Recognizing which one an image needs, from its own documentation, is the actual skill, chapter 8 builds both end to end.

## 5.7 Try it

```sh
kubectl create configmap demo-cm --from-literal=GREETING=hello
kubectl create secret generic demo-secret --from-literal=TOKEN=s3cr3t

kubectl run env-demo --image=busybox:1.36 --restart=Never \
  --overrides='{
    "spec": { "containers": [{
      "name": "env-demo", "image": "busybox:1.36",
      "command": ["sh", "-c", "env | grep -E \"GREETING|TOKEN\" ; sleep 3600"],
      "envFrom": [
        {"configMapRef": {"name": "demo-cm"}},
        {"secretRef": {"name": "demo-secret"}}
      ]
    }]}
  }'
kubectl logs env-demo
kubectl delete pod env-demo configmap demo-cm secret demo-secret
```

Change a ConfigMap value with `kubectl edit configmap demo-cm` while a Pod has it mounted as a volume, `kubectl exec` into the Pod and `cat` the file again after a minute, observe it updated without a restart. Then repeat with `envFrom` and confirm the env var did not change, this difference is worth seeing with your own eyes once.
