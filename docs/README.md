# Kubernetes for backend engineers: operating a real deployment

- Deploys Miniflux (RSS reader) on a Postgres-backed platform layer, using Helm, Kustomize, HashiCorp Vault, and ArgoCD
- Runs entirely on a local `kind` cluster
- No standalone concept chapters — every Kubernetes object (Pod, Deployment, StatefulSet, Service, Ingress, ConfigMap/Secret, RBAC) gets introduced exactly where it's first used
- Every example is the real thing being deployed, never a throwaway placeholder

1. [Local development cluster (kind)](local-cluster-setup.md)
2. [GitOps and the repo layout](gitops-repo-layout.md)
3. [The first real objects, by hand](first-objects-by-hand.md)
4. [Helm: charting Postgres and Miniflux](helm-charts.md)
5. [Kustomize inflating a Helm chart](kustomize-helm-inflation.md)
6. [Vault: secrets as a live service, not a file in git](vault-secrets.md)
7. [ArgoCD: git becomes the source of truth](argocd.md)
8. [Miniflux, end to end](miniflux-deployment.md)
9. [Cheatsheet](cheatsheet.md)
