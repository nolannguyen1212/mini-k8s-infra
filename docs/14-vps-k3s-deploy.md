# 14. VPS: k3s for hosting real projects

Everything through chapter 13 runs on a disposable local kind cluster. This chapter stands up a second, permanent cluster on a single VPS to actually host personal projects on the public internet, and reuses the exact same charts and GitOps repo from chapters 9-12 to deploy to it.

## 14.1 k3s vs a "real" kubeadm cluster, and why

A single VPS (typically 1-2 vCPU, 1-4GB RAM) cannot comfortably run a stock kubeadm control plane (separate etcd, apiserver, controller-manager, scheduler processes, 2GB+ recommended just for the control plane) alongside several personal apps.

k3s is a single ~70MB binary that bundles the apiserver, controller-manager, scheduler, kubelet, and containerd into one process, backed by sqlite instead of etcd for a single node. It is a CNCF-certified Kubernetes distribution, same API, same YAML, same `kubectl`, everything from chapters 1-6 applies unchanged. The only things that differ are cluster bring-up (this chapter) and the parts of chapters 9-12 that mention a specific cluster/context.

k3s also ships with an ingress controller (Traefik), a bare-metal load balancer shim (ServiceLB), and a dynamic storage provisioner (local-path-provisioner) preinstalled, which is why it is the default choice for homelabs and personal VPS boxes. The recommendation here is to disable Traefik and ServiceLB and install `ingress-nginx` instead (14.3), so the Ingress manifests are byte-for-byte identical to the ones already written against kind, one mental model, two clusters. Keep the bundled `local-path-provisioner` for storage, it needs no equivalent replacement.

| | kind (chapter 7) | k3s (this chapter) | kubeadm |
|---|---|---|---|
| Runs on | your laptop, Docker | a VPS, bare OS | a VPS, bare OS |
| Lifetime | disposable, minutes | persistent, months | persistent, months |
| RAM footprint | irrelevant (laptop) | ~512MB-1GB | 2GB+ |
| Ingress/storage | you install ingress-nginx | Traefik/local-path preinstalled (Traefik disabled here) | nothing preinstalled |
| Purpose | learn/iterate | host real traffic | host real traffic, more ceremony for no benefit at this scale |

## 14.2 Harden the box before installing anything

```sh
adduser deploy && usermod -aG sudo deploy   # do not operate as root day to day
ufw default deny incoming
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

Do not open 6443 (the k3s apiserver) to the public internet. It stays reachable over SSH tunnel only (14.3). Everything an end user needs is 80/443.

## 14.3 Install k3s

```sh
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644
```

`--disable traefik --disable servicelb` removes the bundled ingress/LB so `ingress-nginx` (already known from chapter 3) is the only ingress controller in play. `--write-kubeconfig-mode 644` makes `/etc/rancher/k3s/k3s.yaml` readable without sudo for the copy step below.

```sh
systemctl status k3s          # installed as a systemd unit, survives reboots automatically
sudo k3s kubectl get nodes
```

From your laptop, pull the kubeconfig over SSH and merge it as a second context instead of overwriting `~/.kube/config`:

```sh
ssh deploy@<vps-ip> cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s-vps.yaml
# edit /tmp/k3s-vps.yaml: replace 127.0.0.1 with <vps-ip>, rename context/cluster/user to "k3s-vps"
KUBECONFIG=~/.kube/config:/tmp/k3s-vps.yaml kubectl config view --flatten > /tmp/merged && mv /tmp/merged ~/.kube/config
kubectl config get-contexts
kubectl config use-context k3s-vps
```

Now install `ingress-nginx`'s bare-metal manifest (not the kind-specific one from chapter 3, that variant assumes kind's port-mapping trick):

```sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml
kubectl get pods -n ingress-nginx -w
```

On bare metal, `ingress-nginx` runs as a `hostNetwork` Deployment (check the manifest) so it binds 80/443 on the VPS's own network interface directly, no cloud LoadBalancer needed since there is only one node.

## 14.4 Storage: local-path-provisioner

k3s installs `local-path-provisioner` as the default `StorageClass`, backing PVCs with directories on the node's own disk (`/var/lib/rancher/k3s/storage` by default). This is the right tool for a single node: no distributed storage system to operate, and the PV/PVC/StorageClass mechanics from chapter 4 are identical either way.

```sh
kubectl get storageclass          # "local-path" is (default)
```

The one thing to know: a Pod using a `local-path` PVC is pinned to whatever node created the volume. Irrelevant on a single-node cluster, but the reason this StorageClass does not exist by default on multi-node clusters.

## 14.5 Hosting multiple apps on one node

One node, one public IP, one `ingress-nginx`. Multiple apps share all three via host-based routing: each app gets its own `Ingress` object with a distinct `host`, `ingress-nginx` reads the `Host` header and routes to the matching Service.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: go-app
  namespace: go-app
spec:
  ingressClassName: nginx
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: go-app, port: { number: 80 } }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: js-app
  namespace: js-app
spec:
  ingressClassName: nginx
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: js-app, port: { number: 80 } }
```

DNS: point one A record per hostname at the VPS's single IP (`api.example.com` and `app.example.com` both to the same address). Give each app its own namespace (chapter 1.5) so its ConfigMaps, Secrets, and Services never collide by name with another app's.

## 14.6 TLS: cert-manager and Let's Encrypt

Local kind labs never had a publicly reachable IP, so real TLS was never possible there. A VPS does, so get real certificates instead of self-signed ones.

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=available deployment --all -n cert-manager --timeout=180s
```

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef: { name: letsencrypt-prod-key }
    solvers:
      - http01:
          ingress: { ingressClassName: nginx }
```

Add `tls` to each app's Ingress, cert-manager watches the annotation and issues/renews automatically:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts: [api.example.com]
      secretName: go-app-tls
```

```sh
kubectl describe certificate go-app-tls -n go-app     # watch it go Ready
```

## 14.7 GitOps: pointing the same repo at a second cluster

Two ways to extend the ArgoCD setup from chapter 11 to cover the VPS:

1. Register the VPS as an external cluster from the ArgoCD already running in kind (`argocd cluster add k3s-vps`), one ArgoCD manages both.
2. Install a second, independent ArgoCD directly on the VPS, watching the same repo. It reconciles itself (`destination.server: https://kubernetes.default.svc`, since it now runs inside the target cluster).

Option 2 is the better fit for a personal VPS: production no longer depends on your laptop's kind cluster or ArgoCD instance being up. Install ArgoCD on the VPS exactly as in 11.2, then add an `Application` using `values-prod.yaml` (already scaffolded in chapter 12.4):

```yaml
# argocd/apps/go-app-vps.yaml, applied on the VPS's own ArgoCD
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: go-app-vps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-user>/mini-k8s-infra.git
    targetRevision: main
    path: charts/go-app
    helm: { valueFiles: [values-prod.yaml] }
  destination:
    server: https://kubernetes.default.svc
    namespace: go-app
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Same chart built once in chapter 9, same repo, different values file, different cluster. Nothing app-specific is rebuilt for "production," which is the entire point of the values-split from chapter 12.2.

## 14.8 Resource budgeting on a shared node

Every app on this node competes for the same fixed CPU/RAM, so the `resources.requests/limits` from chapter 2 stop being optional. Add a `ResourceQuota` per namespace so one app cannot starve the others:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: { name: go-app-quota, namespace: go-app }
spec:
  hard:
    requests.cpu: "500m"
    requests.memory: 256Mi
    limits.cpu: "1"
    limits.memory: 512Mi
```

```sh
kubectl top nodes
kubectl top pods -A
```

If `kubectl top nodes` shows memory pressure, the fix is lowering a `values.yaml` replica count or request, not adding more apps and hoping.

## 14.9 Backup

k3s's state lives in sqlite at `/var/lib/rancher/k3s/server/db`, not etcd (etcd only enters the picture in k3s's optional multi-server HA mode, unnecessary for one node). Back up that directory on a cron schedule:

```sh
0 3 * * * tar czf /root/backups/k3s-db-$(date +\%F).tar.gz /var/lib/rancher/k3s/server/db
```

Since every app's actual desired state is also sitting in the git repo (chapter 12) and its secrets in Vault (chapter 10), restoring after a total VPS loss is: reinstall k3s (14.3), restore or re-init Vault, re-apply `root-app.yaml` (chapter 11.4), and let ArgoCD reconstruct everything else from git. The sqlite backup only saves you from re-doing that reconstruction by hand.

## 14.10 Try it

1. Point a real domain's A record at the VPS, deploy `go-app` and `js-app` under two different hosts (14.5), and get both served over a real Let's Encrypt certificate (14.6).
2. `sudo systemctl stop k3s`, confirm the site goes down, `sudo systemctl start k3s` (or reboot the box) and confirm it comes back with zero manual `kubectl apply` commands, systemd plus ArgoCD's reconciliation loop should do all of it.
3. Deliberately starve one app's `ResourceQuota` (set it absurdly low), watch its Pod fail to schedule, then explain out loud why that is a chapter 2 (scheduling) problem and not a chapter 11 (GitOps) problem, the same layered-debugging habit from chapter 12.3, now on a cluster that actually matters.
