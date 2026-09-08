# 10. Vault

## 10.1 What problem this solves

Chapter 5/8 put a plaintext secret value straight into a Kubernetes `Secret` manifest (`stringData: API_KEY: local-dev-key-123`). That manifest cannot go into a GitOps repo as-is, base64 is not encryption, anyone who can read the file (or the git history, forever) has the credential. Vault is a secret manager: secrets live encrypted in Vault, never in git, and are fetched into a Pod at runtime by an identity check, not a copy-paste.

Core Vault concepts:

* **Secrets engine**: a backend that stores or generates secrets. `kv-v2` (key/value, versioned) is the one used here, static config-style secrets. Others exist for dynamically generated database credentials, PKI certificates, cloud IAM credentials, not needed for this lab.
* **Auth method**: how a caller proves who it is to Vault. The `kubernetes` auth method lets a Pod authenticate using its own ServiceAccount token (from chapter 6.1), no separate credential to manage.
* **Policy**: an HCL document listing exactly which paths in Vault a given identity may read/write, the Vault equivalent of an RBAC Role.
* **Vault Agent Injector**: a mutating webhook that watches for specific Pod annotations and injects a sidecar container that logs into Vault, fetches secrets, and writes them to a shared `emptyDir` volume the main container can read from.

## 10.2 Install Vault in dev mode

Dev mode runs Vault in-memory, auto-unsealed, with a fixed root token. Never use this outside local learning.

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault \
  --set "server.dev.enabled=true" \
  --set "injector.enabled=true"

kubectl get pods -l app.kubernetes.io/name=vault
kubectl wait --for=condition=Ready pod/vault-0 --timeout=120s
```

```sh
kubectl exec -it vault-0 -- vault status
```

## 10.3 Configure Kubernetes auth and a policy

Everything below runs inside the Vault Pod, `vault-0` is already logged in as root in dev mode.

```sh
kubectl exec -it vault-0 -- sh -c '
  vault auth enable kubernetes

  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"

  vault policy write js-app-policy - <<EOF
path "secret/data/js-app/*" {
  capabilities = ["read"]
}
EOF

  vault write auth/kubernetes/role/js-app \
    bound_service_account_names=js-app \
    bound_service_account_namespaces=default \
    policies=js-app-policy \
    ttl=1h
'
```

What this did: enabled the kubernetes auth method (Vault will call back into the K8s API to validate any token it is handed), wrote a policy granting read on one path prefix, then bound that policy to a specific ServiceAccount name/namespace pair. Only Pods running as ServiceAccount `js-app` in namespace `default` can ever obtain this policy, this is the identity check replacing a shared static credential.

## 10.4 Write the secret

```sh
kubectl exec -it vault-0 -- sh -c '
  vault secrets enable -path=secret kv-v2 || true
  vault kv put secret/js-app/config API_KEY=vault-managed-key-456
  vault kv get secret/js-app/config
'
```

The plaintext `vault-managed-key-456` now exists only inside Vault's storage, never in a file, never in git.

## 10.5 Give js-app the right ServiceAccount

The injector matches on ServiceAccount identity (10.3), so the Deployment must run as one:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: js-app
```

```yaml
spec:
  serviceAccountName: js-app     # add to apps/js-app/k8s/deployment.yaml spec.template.spec
```

## 10.6 Inject the secret via annotations

Add these annotations to the js-app Pod template, no application code changes required, the injector writes a file:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: js-app
spec:
  replicas: 2
  selector:
    matchLabels: { app: js-app }
  template:
    metadata:
      labels: { app: js-app }
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "js-app"
        vault.hashicorp.com/agent-inject-secret-config: "secret/data/js-app/config"
        vault.hashicorp.com/agent-inject-template-config: |
          {{- with secret "secret/data/js-app/config" -}}
          API_KEY={{ .Data.data.API_KEY }}
          {{- end -}}
    spec:
      serviceAccountName: js-app
      containers:
        - name: js-app
          image: js-app:1.0.0
          envFrom:
            - configMapRef: { name: js-app-config }
          # API_KEY now comes from Vault, remove secretRef to js-app-secret entirely
```

The injector adds an init container (fetches the secret once before the app starts) and a sidecar (keeps it refreshed on lease renewal), writing the rendered template to `/vault/secrets/config` inside the Pod, shared via an in-memory volume the injector sets up automatically. The file will contain `API_KEY=vault-managed-key-456` in `.env` format because the template says so, matching exactly the shape js-app already expects.

Since the app currently reads `process.env.API_KEY`, not a file, either switch the app to source that file at startup (`. /vault/secrets/config` semantics, or a tiny loader that reads the file into `process.env`), or change the injector template to a `.json`/raw value and adjust accordingly. This is the one place the file mount vs env var distinction from chapter 5 has real consequences: Vault Agent naturally produces files, an app expecting `envFrom` needs a small shim to bridge the two, this is normal and every real Vault+K8s setup has this exact shim somewhere (an entrypoint script sourcing the file before exec'ing the app is the common fix).

```sh
kubectl apply -f apps/js-app/k8s/serviceaccount.yaml
kubectl apply -f apps/js-app/k8s/deployment.yaml
kubectl get pods -l app=js-app     # expect 2/2 containers ready per pod, not 1/1, the injector sidecar counts
kubectl exec deploy/js-app -c js-app -- cat /vault/secrets/config
```

## 10.7 Why this is strictly better than chapter 8's Secret

| | native k8s Secret | Vault |
|---|---|---|
| plaintext at rest | base64 only, readable by anyone with etcd/API access | encrypted, access gated by policy |
| stored in git | never should be, but nothing stops you | never, only a role/policy name is in git |
| rotation | manual, requires a new manifest + rollout | Vault can rotate and the agent re-fetches on lease renewal |
| audit | K8s audit log only if enabled | Vault has a dedicated audit log of every secret read |
| identity | none, whoever has the YAML has the secret | tied to ServiceAccount identity, revocable independently |

## 10.8 Try it

```sh
kubectl exec -it vault-0 -- vault kv put secret/js-app/config API_KEY=rotated-key-789
kubectl exec deploy/js-app -c js-app -- cat /vault/secrets/config   # wait a moment, observe it updates without a manifest change
```

Then delete the old plaintext Secret entirely and confirm the app still works:

```sh
kubectl delete secret js-app-secret
kubectl rollout restart deployment/js-app
kubectl logs deploy/js-app -c js-app --tail=20
```
