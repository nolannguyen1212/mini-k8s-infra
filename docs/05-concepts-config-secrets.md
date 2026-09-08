# 5. Config and secrets

## 5.1 The rule

Never bake environment-specific config into a container image. Build one image, run it in dev/staging/prod with different config injected at deploy time. Kubernetes gives two objects for this:

* **ConfigMap**: non-sensitive config (feature flags, URLs, log level, a full config file).
* **Secret**: sensitive config (passwords, tokens, keys). Mechanically almost identical to ConfigMap, values are just base64 encoded, not encrypted, at rest unless you enable encryption at the etcd level or use Vault (chapter 10). Treat Secret as "marked sensitive," not as "safe."

Both can reach a container in two ways: as **environment variables** or as a **mounted file**. This choice is the entire story behind your Go/config.yaml vs JS/.env split, covered in 5.4 and 5.5.

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

A ConfigMap can also hold an entire file as one key, this is the pattern used for `config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: go-app-config
data:
  config.yaml: |
    server:
      port: 8080
    log_level: debug
    feature_x: true
```

Or generate it directly from a file, so the file itself stays the source of truth in your repo:

```sh
kubectl create configmap go-app-config --from-file=config.yaml
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

Never commit a rendered Secret (the `data:` base64 form) to git, base64 is encoding not encryption, anyone with the YAML has the plaintext. Chapter 10 (Vault) exists specifically to solve "how do I GitOps a Secret without putting the plaintext in git."

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
  - name: config
    configMap:
      name: go-app-config
containers:
  - name: go-app
    volumeMounts:
      - name: config
        mountPath: /etc/go-app       # config.yaml appears at /etc/go-app/config.yaml
```

This is the pattern for a Go service reading a structured `config.yaml` (viper, koanf, or a hand-rolled `yaml.Unmarshal`), because Go config libraries typically parse a file into a struct, not a flat KEY=value map. Point your app at the mounted path:

```go
viper.SetConfigFile("/etc/go-app/config.yaml")
viper.ReadInConfig()
```

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
| natural fit | flat key/value (.env style) | structured file (yaml/json/ini) |
| Go idiom | less common | common, `config.yaml` |
| Node idiom | common, `process.env` via `.env` | less common |

Practical consequence for this repo's two apps:

* **go-app**: ships `config.yaml`, gets it from a ConfigMap mounted as a volume at a fixed path, app parses it into a struct at startup. If you want config reload without a redeploy, the app itself must watch the file for changes (viper supports this via `WatchConfig`), the mount updates automatically, your code decides whether to react.
* **js-app**: reads `process.env.*`, gets those values from a ConfigMap and a Secret both projected via `envFrom`, no file involved, changing a value requires a rolling restart of the Deployment (`kubectl rollout restart deployment/js-app`) because env vars are frozen at container start.

Both are legitimate, generic patterns, not a hack: file mount for structured config that a language's ecosystem expects as a file, `envFrom` for flat config that a language's ecosystem expects as environment variables. Chapter 8 builds both end to end.

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
