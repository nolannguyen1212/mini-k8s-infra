# 12. ksops: encrypted secrets as a Kustomize generator

Chapter 10 encrypted and decrypted a file by hand. Chapter 11 got Kustomize inflating a Helm chart. This chapter connects them, and replaces chapter 8's plaintext `Secret` manifests with something safe to commit: ksops is a Kustomize **generator plugin** that decrypts a `secrets.enc.yaml` and emits the resulting `Secret` as part of the same `kustomize build` that renders the chart.

## 12.1 Put the ksops binary where Kustomize's plugin loader expects it

```sh
mkdir -p ~/.config/kustomize/plugin/viaduct.ai/v1/ksops
cp "$(which ksops)" ~/.config/kustomize/plugin/viaduct.ai/v1/ksops/ksops
chmod +x ~/.config/kustomize/plugin/viaduct.ai/v1/ksops/ksops
```

One-time, per-machine setup, not something that lives in the repo — chapter 13's ArgoCD sidecar has its own copy baked into its image.

## 12.2 Postgres's secret

```sh
cat > apps/platform/postgres/secrets.enc.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
type: Opaque
stringData:
  POSTGRES_PASSWORD: change-me-superuser-password
  MINIFLUX_DB_PASSWORD: change-me-miniflux-db-password
EOF
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -e -i apps/platform/postgres/secrets.enc.yaml
```

`apps/platform/postgres/ksops-generator.yaml`:

```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: postgres-secrets
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./secrets.enc.yaml
```

Add it to `apps/platform/postgres/kustomization.yaml` — the only change to the file chapter 11 already built:

```yaml
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

generators:
  - ksops-generator.yaml
```

## 12.3 Build it, and the two errors you're expected to hit first

```sh
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone apps/platform/postgres
```

```
Error: loading generator plugins: failed to load generator: external plugins disabled; unable to load external plugin 'ksops'
```

Kustomize disables loading any generator plugin by default. Two more flags fix it:

```sh
kustomize build --enable-helm --enable-alpha-plugins --enable-exec --load-restrictor LoadRestrictionsNone apps/platform/postgres
```

`--enable-alpha-plugins` allows loading a generator plugin at all; `--enable-exec` allows this specific kind (an executable invoked via the `config.kubernetes.io/function: exec:` annotation in 12.2's generator file) to actually run. Both are required together; dropping either reproduces the same "external plugins disabled" error.

With both flags, the error changes:

```
failed to evaluate function: error decrypting file "./secrets.enc.yaml" from manifest.Files: trouble decrypting file: Error getting data key: 0 successful groups required, got 0
```

This means ksops can't find a usable age private key:

```sh
SOPS_AGE_KEY_FILE=age/keys.txt kustomize build --enable-helm --enable-alpha-plugins --enable-exec --load-restrictor LoadRestrictionsNone apps/platform/postgres
```

Same error, still — **the path must be absolute**, a relative path fails with this exact same misleading message, giving no hint the path itself is the problem:

```sh
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt kustomize build --enable-helm --enable-alpha-plugins --enable-exec --load-restrictor LoadRestrictionsNone apps/platform/postgres
```

This now renders Postgres's full chart plus a decrypted `Secret` — plaintext, right there in the terminal output. That plaintext exists only in this command's output and your own terminal history, never in a file, never in git.

## 12.4 Miniflux's secret

Different namespace (`miniflux`, not `platform`), and the password inside `DATABASE_URL` has to be the exact same value as 12.2's `MINIFLUX_DB_PASSWORD`:

```sh
cat > apps/miniflux/secrets.enc.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: miniflux-secret
type: Opaque
stringData:
  DATABASE_URL: "postgres://miniflux:change-me-miniflux-db-password@postgres.platform.svc.cluster.local:5432/miniflux?sslmode=disable"
  ADMIN_USERNAME: admin
  ADMIN_PASSWORD: change-me-a-real-admin-password
EOF
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -e -i apps/miniflux/secrets.enc.yaml
```

`apps/miniflux/ksops-generator.yaml` — identical shape to 12.2's:

```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: miniflux-secrets
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./secrets.enc.yaml
```

Add `generators: [ksops-generator.yaml]` to `apps/miniflux/kustomization.yaml` the same way.

This is not an accident of copy-pasting a placeholder: because Postgres has no operator minting per-app credentials automatically, the password for the `miniflux` role genuinely has to exist in **two** independently-encrypted files, and nothing automatically keeps them in sync. Chapter 17 covers what rotating this actually looks like.

## 12.5 Redis and MinIO

```sh
cat > apps/platform/redis/secrets.enc.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: redis-secret
type: Opaque
stringData:
  REDIS_PASSWORD: change-me-a-real-password
EOF
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -e -i apps/platform/redis/secrets.enc.yaml

cat > apps/platform/minio/secrets.enc.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
type: Opaque
stringData:
  MINIO_ROOT_USER: change-me-minio-user
  MINIO_ROOT_PASSWORD: change-me-minio-password
EOF
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -e -i apps/platform/minio/secrets.enc.yaml
```

Both get a `ksops-generator.yaml` identical in shape (only `metadata.name` differs, by convention `<app>-secrets`), and both `kustomization.yaml`s get the same `generators:` line added. `kafka` gets neither — chapter 9.4 already covered why it needs no secret.

## 12.6 Delete chapter 8's plaintext Secrets

```sh
kubectl delete secret postgres-secret -n platform
kubectl delete secret miniflux-secret -n miniflux
```

They come back, decrypted, the moment chapter 13's ArgoCD syncs these overlays for real. Deleting them now is what proves the plaintext YAML files from chapter 8 were never actually needed again — everything downstream reads from the encrypted files instead.

## 12.7 Try it

```sh
for app in platform/postgres platform/redis platform/minio miniflux; do
  echo "=== $app ==="
  SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt kustomize build \
    --enable-helm --enable-alpha-plugins --enable-exec --load-restrictor LoadRestrictionsNone \
    apps/$app | grep -A6 "kind: Secret"
done

grep -l "change-me" apps/platform/*/secrets.enc.yaml apps/miniflux/secrets.enc.yaml || echo "none — every committed file is encrypted"
```

Then verify the two passwords that must match actually do, the way a careless copy-paste later won't:

```sh
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -d apps/platform/postgres/secrets.enc.yaml | grep MINIFLUX_DB_PASSWORD
SOPS_AGE_KEY_FILE=$(pwd)/age/keys.txt sops -d apps/miniflux/secrets.enc.yaml | grep DATABASE_URL
```
