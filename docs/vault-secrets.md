# Vault: secrets as a live service, not a file in git

- [The first real objects, by hand](first-objects-by-hand.md) put two plaintext passwords straight into `Secret` manifests
- Those manifests cannot go into git as-is: base64 is not encryption, anyone who can read the file (or the git history, forever) has the credential
- A common alternative to what's built here is SOPS+age: encrypt the file, commit the ciphertext, decrypt at render time
- This repo uses Vault instead: secrets never exist as a file, encrypted or not, anywhere in git
- A running Pod fetches its secret over the network, from a running Vault service, at the moment it starts
- The direct consequence, and the reason this chapter exists: rotating a secret later is one `vault kv put` command, not a file edit, a commit, and a push

## The mechanical difference this creates

A SOPS-based pipeline decrypts at **render time**: something (ArgoCD, `kustomize build`) turns an encrypted file into a plaintext `Secret` object as part of producing the manifests that get applied. Vault instead injects at **admission time**: a mutating webhook watches for a specific annotation on a Pod spec, and rewrites the Pod to add an init container (and a sidecar) that authenticates to Vault using the Pod's own identity and writes the secret to a file inside the Pod, before the main container ever starts. Nothing about `kustomize build` or ArgoCD changes because of this: [ArgoCD: git becomes the source of truth](argocd.md)'s ArgoCD install ends up simpler than a SOPS-based one would, since it never needs to hold a decryption key at all.

## Install Vault (dev mode)

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
helm install vault hashicorp/vault -n vault \
  --set "server.dev.enabled=true" \
  --set "injector.enabled=true"
```

`server.dev.enabled=true` runs a single Vault replica with in-memory storage, auto-unsealed, a fixed root token printed straight into the Pod's own logs: the right choice for iterating locally, wrong for anything meant to survive a restart (production mode trades this for persistent storage and a manual unseal step, deliberately out of scope here since this repo stops at local operation, not production hardening). `injector.enabled=true` is the second component this chapter depends on: the mutating admission webhook that actually rewrites Pods ([The Agent Injector annotations, and the templating-inside-templating gotcha](#the-agent-injector-annotations-and-the-templating-inside-templating-gotcha)).

```sh
kubectl get pods -n vault                      # vault-0 and vault-agent-injector-*, both Running
kubectl logs -n vault vault-0 | grep "Root Token"
```

```sh
kubectl port-forward -n vault svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root token from above>
vault status                                    # Sealed: false, confirms dev mode is actually usable
```

## Write the secrets

Dev mode auto-mounts a KV v2 engine at `secret/`. `vault kv get`/`put` work immediately, no `vault secrets enable` step needed here: a non-dev install would need that step explicitly first:

```sh
vault kv put secret/platform/postgres \
  POSTGRES_PASSWORD=dev-superuser-password \
  MINIFLUX_DB_PASSWORD=dev-miniflux-db-password

vault kv put secret/miniflux \
  ADMIN_USERNAME=admin \
  ADMIN_PASSWORD=dev-admin-password

vault kv get secret/platform/postgres
```

Notice `DATABASE_URL` is not written anywhere: [The Agent Injector annotations, and the templating-inside-templating gotcha](#the-agent-injector-annotations-and-the-templating-inside-templating-gotcha) composes it inside the Pod, at injection time, directly from `secret/platform/postgres`'s `MINIFLUX_DB_PASSWORD`. That's the specific thing that removes [The first real objects, by hand](first-objects-by-hand.md)'s two-copies-of-one-password problem: Miniflux's Vault Agent reads the **same path** Postgres's does, instead of a second, independently-maintained copy of the value.

## The Kubernetes auth method

Vault needs to know how to trust a Pod's identity. The `kubernetes` auth method verifies a Pod's own ServiceAccount token against the cluster's API: run this from inside `vault-0` itself, the most reliable way to get the in-cluster host/CA right without fighting TLS from your laptop:

```sh
kubectl exec -it vault-0 -n vault -- vault auth enable kubernetes

kubectl exec -it vault-0 -n vault -- vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"
```

## Policies and roles, scoped per app

A policy grants read on a specific KV path. A role binds a Kubernetes ServiceAccount identity (namespace + name) to a policy: this is what actually authorizes a given Pod to read a given secret, nothing broader:

```sh
cat > postgres-policy.hcl <<'EOF'
path "secret/data/platform/postgres" {
  capabilities = ["read"]
}
EOF

cat > miniflux-policy.hcl <<'EOF'
path "secret/data/platform/postgres" {
  capabilities = ["read"]
}
path "secret/data/miniflux" {
  capabilities = ["read"]
}
EOF
```

Miniflux's policy includes Postgres's own path on purpose: it needs to read `MINIFLUX_DB_PASSWORD` directly to compose its `DATABASE_URL` (see [Write the secrets](#write-the-secrets)). This is the mechanism, not a mistake: two apps can share a read path in Vault the same way they can share a K8s `Secret`, except each grant is explicit and auditable per role instead of implied by which Pods happen to mount which object.

```sh
kubectl cp postgres-policy.hcl vault/vault-0:/tmp/postgres-policy.hcl
kubectl cp miniflux-policy.hcl vault/vault-0:/tmp/miniflux-policy.hcl
kubectl exec -it vault-0 -n vault -- vault policy write postgres /tmp/postgres-policy.hcl
kubectl exec -it vault-0 -n vault -- vault policy write miniflux /tmp/miniflux-policy.hcl

kubectl exec -it vault-0 -n vault -- vault write auth/kubernetes/role/postgres \
  bound_service_account_names=postgres \
  bound_service_account_namespaces=platform \
  policies=postgres \
  ttl=1h

kubectl exec -it vault-0 -n vault -- vault write auth/kubernetes/role/miniflux \
  bound_service_account_names=miniflux \
  bound_service_account_namespaces=miniflux \
  policies=miniflux \
  ttl=1h
```

`bound_service_account_names=postgres` means a Pod authenticates as this role only if it runs under a ServiceAccount literally named `postgres`, in namespace `platform`: not the namespace's `default` ServiceAccount every Pod gets otherwise. [ServiceAccounts, added to both charts](#serviceaccounts-added-to-both-charts) adds that ServiceAccount to both charts.

## ServiceAccounts, added to both charts

`charts/postgres/templates/serviceaccount.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Release.Name }}
```

`charts/miniflux/templates/serviceaccount.yaml`: identical shape. `{{ .Release.Name }}` already equals `postgres`/`miniflux` ([Helm: charting Postgres and Miniflux](helm-charts.md)), matching [Policies and roles, scoped per app](#policies-and-roles-scoped-per-app)'s `bound_service_account_names` exactly.

Add `serviceAccountName: {{ .Release.Name }}` to both `spec.template.spec` blocks (`charts/postgres/templates/statefulset.yaml`, `charts/miniflux/templates/deployment.yaml`): this is the field that actually tells the Pod which ServiceAccount's token to present, both to the Kubernetes API and, in [The Agent Injector annotations, and the templating-inside-templating gotcha](#the-agent-injector-annotations-and-the-templating-inside-templating-gotcha), to Vault.

## The Agent Injector annotations, and the templating-inside-templating gotcha

Annotations on the **Pod template** (`spec.template.metadata.annotations`, not the workload's own `metadata`) are what the injector webhook actually reads. `charts/postgres/templates/statefulset.yaml`, updated:

```yaml
spec:
  template:
    metadata:
      labels: { app: {{ .Release.Name }} }
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "postgres"
        vault.hashicorp.com/agent-inject-secret-config: "secret/data/platform/postgres"
        vault.hashicorp.com/agent-inject-template-config: |
          {{`{{- with secret "secret/data/platform/postgres" -}}`}}
          export POSTGRES_PASSWORD="{{`{{ .Data.data.POSTGRES_PASSWORD }}`}}"
          export MINIFLUX_DB_PASSWORD="{{`{{ .Data.data.MINIFLUX_DB_PASSWORD }}`}}"
          {{`{{- end }}`}}
    spec:
      serviceAccountName: {{ .Release.Name }}
      containers:
        - name: postgres
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["sh", "-c"]
          args:
            - . /vault/secrets/config && exec docker-entrypoint.sh postgres
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_USER
              value: postgres
          # envFrom: secretRef postgres-secret (removed, no Secret object exists anymore)
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data, subPath: pgdata }
            - { name: init, mountPath: /docker-entrypoint-initdb.d }
```

Two things worth stopping on:

* **`{{`  `}}`{{`}}`` around the Vault template body.** Vault Agent's own template language (Consul Template) uses `{{ .Data.data.X }}` syntax: identical delimiters to Helm's own. Left unescaped, Helm tries to render `{{ .Data.data.POSTGRES_PASSWORD }}` itself at `helm template` time and fails (`.Data` isn't a value in Helm's context) or silently renders empty. Wrapping each `{{ ... }}` as `{{` followed by a backtick-quoted literal is Helm's own escape hatch for "treat this text as a literal string, don't parse it as a Helm action": the output written to the chart is the literal four characters `{{ .Data.data...`, which Vault Agent then parses on its own, once the file actually lands in the Pod. The exact same category of problem as [Chart Postgres](helm-charts.md#chart-postgres)'s `${{ .passwordSecretKey }}`, one layer up.
* **`command`/`args` override.** The Vault Agent Injector does not set real environment variables: it renders `agent-inject-template-config` to a file at `/vault/secrets/config` inside the Pod, before the main container's entrypoint runs. The `postgres` image (like most images not written with Vault in mind) only reads real env vars, so the container's own command has to `source` that file first. `. /vault/secrets/config && exec docker-entrypoint.sh postgres` is that: dot-source the rendered exports, then `exec` the image's actual entrypoint so it becomes PID 1 with those vars now present in its environment.

`charts/miniflux/templates/deployment.yaml`, updated the same way: two named secrets this time, since Miniflux reads from two different Vault paths:

```yaml
spec:
  template:
    metadata:
      labels: { app: {{ .Release.Name }} }
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "miniflux"
        vault.hashicorp.com/agent-inject-secret-postgres: "secret/data/platform/postgres"
        vault.hashicorp.com/agent-inject-template-postgres: |
          {{`{{- with secret "secret/data/platform/postgres" -}}`}}
          export DATABASE_URL="postgres://miniflux:{{`{{ .Data.data.MINIFLUX_DB_PASSWORD }}`}}@postgres.platform.svc.cluster.local:5432/miniflux?sslmode=disable"
          {{`{{- end }}`}}
        vault.hashicorp.com/agent-inject-secret-miniflux: "secret/data/miniflux"
        vault.hashicorp.com/agent-inject-template-miniflux: |
          {{`{{- with secret "secret/data/miniflux" -}}`}}
          export ADMIN_USERNAME="{{`{{ .Data.data.ADMIN_USERNAME }}`}}"
          export ADMIN_PASSWORD="{{`{{ .Data.data.ADMIN_PASSWORD }}`}}"
          {{`{{- end }}`}}
    spec:
      serviceAccountName: {{ .Release.Name }}
      containers:
        - name: miniflux
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["sh", "-c"]
          args:
            - . /vault/secrets/postgres && . /vault/secrets/miniflux && exec miniflux
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - { name: RUN_MIGRATIONS, value: "1" }
            - { name: CREATE_ADMIN, value: "1" }
          # envFrom: secretRef miniflux-secret (removed, no Secret object exists anymore)
```

The `-secret-<name>`/`-template-<name>` suffix (`postgres`, `miniflux`) is what lets one Pod render more than one file (`/vault/secrets/postgres` and `/vault/secrets/miniflux`), each independently, from independently-scoped policy reads.

## Try it

```sh
helm upgrade --install postgres charts/postgres -n platform
kubectl rollout status statefulset/postgres -n platform
kubectl get pod postgres-0 -n platform     # 3/3 Ready: postgres + vault-agent-init (completed) + vault-agent (sidecar)
kubectl exec postgres-0 -n platform -c postgres -- printenv | grep -E "POSTGRES_PASSWORD|MINIFLUX_DB_PASSWORD"

helm upgrade --install miniflux charts/miniflux -n miniflux
kubectl rollout status deployment/miniflux -n miniflux
kubectl exec deploy/miniflux -n miniflux -c miniflux -- printenv | grep DATABASE_URL
```

The extra sidecar container (not just the init container) keeps running for the Pod's whole lifetime, re-rendering `/vault/secrets/*` whenever the underlying value changes or the lease needs renewing: this is what makes a later `vault kv put` propagate into a *running* Pod's filesystem without anything touching git. Whether the running **process** picks up a rewritten file without a restart is a separate question: [Prove the failure modes, not just the happy path](miniflux-deployment.md#prove-the-failure-modes-not-just-the-happy-path) covers exactly what that does and doesn't do here.
