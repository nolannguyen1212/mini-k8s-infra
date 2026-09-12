# Kubernetes deep dive for backend engineers

Chapters 1-6 cover the core objects (Pod, Deployment, StatefulSet, Service, Ingress, ConfigMap/Secret, RBAC). Chapter 7 onward builds one real thing continuously — `k8s-deploy`, a repo hosting a real app (Miniflux) on a shared Postgres/Redis/Kafka/MinIO platform layer, managed with Helm, Kustomize, SOPS-encrypted secrets, and ArgoCD — first on a local `kind` cluster, then on a real VPS running k3s (chapter 15).

1. [Core concepts](01-concepts-core.md)
2. [Workloads](02-concepts-workloads.md)
3. [Networking](03-concepts-networking.md)
4. [Storage](04-concepts-storage.md)
5. [Config and secrets](05-concepts-config-secrets.md)
6. [Security and RBAC](06-concepts-security-rbac.md)
7. [Local development cluster (kind)](07-local-cluster-setup.md)
8. [The first real objects, by hand](08-first-objects-by-hand.md)
9. [Helm: charting everything](09-helm-charts.md)
10. [Secrets: SOPS and age](10-secrets-sops-age.md)
11. [Kustomize inflating a Helm chart](11-kustomize-helm-inflation.md)
12. [ksops: encrypted secrets as a Kustomize generator](12-ksops.md)
13. [ArgoCD, with the ksops plugin from the start](13-argocd.md)
14. [App-of-apps, sync waves, and the GitOps repo layout](14-gitops-repo-layout.md)
15. [VPS: k3s](15-vps-k3s.md)
16. [Cheatsheet](16-cheatsheet.md)
17. [Operations: adding an app, rotating a secret, and what comes next](17-operations.md)
