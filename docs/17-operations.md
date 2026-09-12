# 17. Operations: adding an app, rotating a secret, and what comes next

## 17.1 Adding a new app

1. `charts/<name>/` — a Helm chart. Copy `charts/miniflux/` as a starting point for a simple single-container HTTP app.
2. `apps/<name>/kustomization.yaml` + `ksops-generator.yaml` (copy verbatim) + `secrets.enc.yaml` if it needs one:
   ```sh
   sops -e -i apps/<name>/secrets.enc.yaml   # after writing it as plaintext first
   ```
3. If it needs its own Postgres database: add one entry to `charts/postgres/values.yaml`'s `roles:` list, and add the matching `<NAME>_DB_PASSWORD` key to `apps/platform/postgres/secrets.enc.yaml` (`sops apps/platform/postgres/secrets.enc.yaml`, edit, save).
4. If it needs its own namespace: add `environments/namespace-<name>.yaml`, and add one `namespaceSelector` entry to `environments/networkpolicy-platform-allow-consumers.yaml` if it needs to reach the platform layer.
5. `argocd/apps/<name>.yaml` — copy an existing `Application`, change `name`/`path`/`destination.namespace`/`sync-wave` (needs-postgres apps go one wave after `platform-postgres`, same reasoning as `miniflux`'s wave `0`).
6. Commit, push. The root app-of-apps (chapter 14.5) picks up the new `Application` automatically, `directory.recurse: true` means nothing else needs editing.

## 17.2 Rotating a secret

Simple case, no shared credential involved:

```sh
sops apps/<app>/secrets.enc.yaml
git add -A && git commit -m "rotate <whatever>" && git push
```

`selfHeal` (chapter 13.6) picks it up on the next poll (or `argocd app sync <name>` immediately) and restarts the Pod. Env vars are frozen at container start (chapter 5.6's rule, unchanged) — a `Secret` update alone does not re-authenticate an already-running process, only a fresh one.

The harder case: a Postgres role's password lives in **two** files because chapter 9.1's design has no operator minting per-app credentials.

```sh
sops apps/platform/postgres/secrets.enc.yaml       # edit <NAME>_DB_PASSWORD
sops apps/<app>/secrets.enc.yaml                     # edit DATABASE_URL's password to match
git add -A && git commit -m "rotate <app> db password" && git push
```

Changing `postgres-secret`'s env var does **not** retroactively `ALTER ROLE` an already-created role — the init script (chapter 8.2/9.1) only runs once, against an empty data volume. A real rotation needs a follow-up statement run by hand against the live instance:

```sh
kubectl exec -it postgres-0 -n platform -- psql -U postgres -c "ALTER ROLE <app> WITH PASSWORD 'the-new-password';"
```

Redis has the same shape of problem (`apps/platform/redis/secrets.enc.yaml`'s `REDIS_PASSWORD` vs. whatever consumes it) — same two-file edit, same "the running process needs restarting, not just told" caveat (`kubectl rollout restart statefulset/redis -n platform`).

## 17.3 Known scope cuts, and when to revisit them

- Kafka runs with no auth — acceptable only because chapter 14's NetworkPolicy already restricts who can reach `platform` at all. Revisit before this is ever multi-tenant.
- One instance each of Postgres/Redis/Kafka/MinIO, no HA — fine for one personal VPS; a real operator (CloudNativePG, a managed Kafka) is the answer beyond that, not more StatefulSet replicas hand-managed the way chapter 9 built them.
- Image tags across every `values.yaml` in this repo are placeholders (`latest`, or an unpinned MinIO release) — pin real, immutable tags before this matters for anything you'd be upset to lose.
- The `viaductoss/ksops` sidecar image tag and exact `argo-helm` chart field names (chapter 13.4) need reverifying against whatever is current whenever this is actually installed — both have shifted across releases since this was written.

## 17.4 What comes next: lumiere and media-notes

Everything above was built and rehearsed on Miniflux specifically so this section can be a pointer, not another full walkthrough — the pattern is proven, applying it is now mechanical, following 17.1's steps.

**lumiere** (Django/DRF/Channels, real repo at `repos/lumiere`) does *not* need Postgres or Redis: `lumiere/settings/production.py` hardcodes `django.db.backends.sqlite3`, and its Channels layer is in-memory, not Redis-backed. It needs a `PersistentVolumeClaim` instead (chapter 4's mechanism) mounted at **two** separate paths — `DATA_DIR` (env-configurable, holds the sqlite file) and `BASE_DIR/media` (hardcoded in `settings/base.py`, not env-configurable, easy to miss and lose uploaded files to ephemeral storage if only the first is mounted). It cannot run more than `replicas: 1` — concurrent Pods writing one SQLite file is a corruption risk, not just a performance concern. Its secret needs `SECRET_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, and the `DJANGO_SUPERUSER_*` bootstrap variables listed in the repo's own `.env.example`.

**media-notes** (real repo at `repos/media-notes`) is nine deployable units: six Go services (`identity`, `billing`, `media`, `content`, `conductor`, `hermes`) each following the exact http(+grpc)+`DATABASE_URL`+`KAFKA_BROKERS` shape chapter 8's Miniflux already demonstrates for the http+`DATABASE_URL` half — read each service's own `internal/app/config.go` for its exact env var names before writing its chart, the way this repo's chapters read `services/identity/internal/app/config.go` and `services/hermes/internal/app/config.go` rather than guessing. `repos/media-notes/deploy/postgres/init/*.sql` already defines one Postgres role+database per service, matching chapter 9.1's design exactly — add one `roles:` entry per service, this was already the real repo's own intended design before this repo existed. `worker` (Python, a pure Kafka consumer) needs no `Service` at all. `web` (React, port 3000) is the one to check carefully before copying `hermes`'s Ingress onto it: `hermes` is a GraphQL gateway, `web` is the frontend the browser loads first — confirm which one the browser actually talks to directly before deciding which gets the public `Ingress`.

With six near-identical Go services instead of one Miniflux, the repeated Deployment+Service+probe shape (chapter 9's Miniflux template) is worth factoring into a Helm **library chart** — `type: library` in its `Chart.yaml`, no rendered output of its own, consumed by each service's chart via a `dependencies:` entry (`repository: file://../_lib/go-service`) plus `helm dependency update`, called from each consuming chart's own templates via `{{ include "go-service.deployment" . }}`. One Miniflux never justified building this abstraction; six services copy-pasting the same 40-line Deployment template would.

## 17.5 Try it

1. Rotate Miniflux's admin password end to end (17.2's simple case), then actually log into Miniflux with the new password to confirm it took effect, not just that the `Secret` changed.
2. Pick one of media-notes' services and write its chart + overlay + `Application`, following 17.1, without deploying it (no k3s access needed for this exercise, `helm lint`/`kustomize build` are enough to prove the manifests are correct). Compare against `identity`'s actual `internal/app/config.go` to confirm every env var name is exact, not approximate.
3. Explain out loud, without notes, why lumiere's `MEDIA_ROOT` gotcha exists — what would happen to uploaded files if only `DATA_DIR` were mounted, and why the settings file itself is what forces the second mount path rather than a choice this repo made.
