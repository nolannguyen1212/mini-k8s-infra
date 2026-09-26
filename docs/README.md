# Kubernetes for backend engineers: operating a real deployment

This docs set builds one real thing continuously on a local `kind` cluster — this repo, hosting a real app (Miniflux) on a Postgres-backed platform layer, managed with Helm, Kustomize, HashiCorp Vault, and ArgoCD. No standalone concept chapters: every Kubernetes object (Pod, Deployment, StatefulSet, Service, Ingress, ConfigMap/Secret, RBAC) is introduced at the point it's actually used, against the actual thing this repo deploys, not a throwaway example. HA, multi-node, and production/VPS operations are explicitly out of scope — the goal here is running one real stack correctly end to end, locally, first.

Read in this order:

1. [Local development cluster (kind)](local-cluster-setup.md)
2. [GitOps and the repo layout](gitops-repo-layout.md)
3. [The first real objects, by hand](first-objects-by-hand.md)
4. [Helm: charting Postgres and Miniflux](helm-charts.md)
5. [Kustomize inflating a Helm chart](kustomize-helm-inflation.md)
6. [Vault: secrets as a live service, not a file in git](vault-secrets.md)
7. [ArgoCD: git becomes the source of truth](argocd.md)
8. [Miniflux, end to end](miniflux-deployment.md)
9. [Cheatsheet](cheatsheet.md)
