# Kubernetes operations lab

- Deploys Miniflux (RSS reader) on a Postgres-backed platform layer, using Helm, Kustomize, HashiCorp Vault, and ArgoCD
- Runs entirely on a local `kind` cluster
- No standalone concept chapters: every Kubernetes object (Pod, Deployment, StatefulSet, Service, Ingress, ConfigMap/Secret, RBAC) gets introduced exactly where it's first used
- Every example is the real thing being deployed, never a throwaway placeholder

### Index
- [Local development cluster (kind)](local-cluster-setup.md)
- [GitOps and the repo layout](gitops-repo-layout.md)
- [Raw manifests](raw-manifests.md)
- [Helm: charting Postgres and Miniflux](helm-charts.md)
- [Kustomize inflating a Helm chart](kustomize-helm-inflation.md)
- [Vault: secrets as a live service, not a file in git](vault-secrets.md)
- [ArgoCD: git becomes the source of truth](argocd.md)
- [Miniflux, end to end](miniflux-deployment.md)
- [Observability: watching what's actually running](observability.md)
- [Cheatsheet](cheatsheet.md)
