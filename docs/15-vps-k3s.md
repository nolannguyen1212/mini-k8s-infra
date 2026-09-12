# 15. VPS: k3s

Everything through chapter 14 runs on a local kind cluster. This chapter stands up a second, permanent cluster on a single VPS to actually host this on the public internet, and points the exact same repo at it — same charts, same overlays, same ArgoCD wiring, just a different `destination.server` and a real domain instead of `miniflux.local`.

## 15.1 k3s vs a "real" kubeadm cluster, and why

A single VPS (typically 1-2 vCPU, 1-4GB RAM) cannot comfortably run a stock kubeadm control plane (separate etcd, apiserver, controller-manager, scheduler processes, 2GB+ recommended just for the control plane) alongside the actual apps.

k3s is a single ~70MB binary that bundles the apiserver, controller-manager, scheduler, kubelet, and containerd into one process, backed by sqlite instead of etcd for a single node. It is a CNCF-certified Kubernetes distribution, same API, same YAML, same `kubectl` — everything from chapters 1-6 applies unchanged. Only cluster bring-up (this chapter) and the parts of chapters 13-14 that mention a specific cluster/context differ.

k3s ships with an ingress controller (Traefik), a bare-metal load balancer shim (ServiceLB), and a dynamic storage provisioner (local-path-provisioner) preinstalled. Disable Traefik and ServiceLB and install `ingress-nginx` instead (15.3), so the Ingress manifests already written are byte-for-byte identical between kind and k3s — one mental model, two clusters. Keep the bundled `local-path-provisioner` for storage.

| | kind (local) | k3s (this chapter) |
|---|---|---|
| Runs on | your laptop, Docker | a VPS, bare OS |
| Lifetime | disposable, minutes | persistent, months |
| RAM footprint | irrelevant (laptop) | ~512MB-1GB |
| Ingress/storage | you install ingress-nginx | Traefik/local-path preinstalled (Traefik disabled here) |
| Purpose | iterate fast | host real traffic |

## 15.2 Harden the box before installing anything

```sh
adduser deploy && usermod -aG sudo deploy   # do not operate as root day to day
ufw default deny incoming
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

Do not open 6443 (the k3s apiserver) to the public internet, it stays reachable over SSH tunnel only. Everything an end user needs is 80/443.

## 15.3 Install k3s

```sh
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644
```

```sh
systemctl status k3s
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

Install `ingress-nginx`'s bare-metal manifest (not the kind-specific one from chapter 3, that variant assumes kind's port-mapping trick):

```sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml
kubectl get pods -n ingress-nginx -w
```

On bare metal, `ingress-nginx` runs as a `hostNetwork` Deployment, binding 80/443 on the VPS's own network interface directly, no cloud LoadBalancer needed since there is only one node.

## 15.4 Point this repo at the VPS

Everything from chapter 10 onward exists as files in `k8s-deploy` already. Bootstrapping this second cluster is chapters 10.5 and 13 again, against a new context, not new material:

```sh
kubectl config use-context k3s-vps

# secret zero, again — this cluster's ArgoCD needs its own copy of the age key
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic sops-age -n argocd --from-file=age.agekey=age/keys.txt

helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd -f argocd/values-argocd.yaml
kubectl apply -f argocd/cmp/ksops-cmp.yaml -n argocd
kubectl apply -f argocd/projects/default.yaml
kubectl apply -f argocd/root.yaml
```

The same `age/keys.txt` (backed up outside this repo, chapter 10.5) works against any cluster — the key isn't cluster-specific, only the Kubernetes Secret holding it is, and that has to be created on every cluster this repo ever targets.

## 15.5 TLS: cert-manager and Let's Encrypt

Local kind never had a publicly reachable IP, so real TLS was never possible there. A VPS does:

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

Add `tls` to `charts/miniflux/templates/ingress.yaml`, and update `values-prod.yaml`'s `host` to the real domain:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts: [{{ .Values.host }}]
      secretName: {{ .Release.Name }}-tls
```

```sh
kubectl describe certificate miniflux-tls -n miniflux     # watch it go Ready
```

Point an A record for the real domain at the VPS's IP before this — cert-manager's `http01` solver needs the domain to actually resolve to this box to complete the ACME challenge.

## 15.6 Resource budgeting on a shared node

Every workload on this node competes for the same fixed CPU/RAM, so `resources.requests/limits` (chapter 2.6) stop being optional. Add a `ResourceQuota` per namespace so one workload cannot starve the rest:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: { name: miniflux-quota, namespace: miniflux }
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

If `kubectl top nodes` shows memory pressure, the fix is lowering a `values-prod.yaml` replica count or request, not adding more workloads and hoping.

## 15.7 Backup

k3s's state lives in sqlite at `/var/lib/rancher/k3s/server/db`, not etcd. Back it up on a cron schedule:

```sh
0 3 * * * tar czf /root/backups/k3s-db-$(date +\%F).tar.gz /var/lib/rancher/k3s/server/db
```

Since desired state also sits in this git repo and secrets are encrypted files inside it (plus the one off-git age key, chapter 10.5), restoring after a total VPS loss is: reinstall k3s (15.3), recreate the `sops-age` Secret from the backed-up key, re-apply `argocd/root.yaml`, and let ArgoCD reconstruct everything else from git. The sqlite backup only saves you from re-doing that reconstruction by hand.

## 15.8 Try it

1. Point a real domain's A record at the VPS, get miniflux served over a real Let's Encrypt certificate.
2. Confirm Postgres/Redis/Kafka/MinIO are unreachable from outside the cluster (`curl`/`nc` from your laptop against the VPS IP on 5432/6379/9092/9000, expect a timeout) — chapter 3's Ingress rule and chapter 14's NetworkPolicy, now on a cluster that actually matters.
3. `sudo systemctl stop k3s`, confirm the site goes down, `sudo systemctl start k3s` (or reboot the box) and confirm it comes back with zero manual `kubectl apply` — systemd plus ArgoCD's reconciliation loop should do all of it.
4. Deliberately starve `miniflux-quota` (set it absurdly low), watch the Pod fail to schedule, then explain out loud why that's a chapter 2 (scheduling) problem, not a chapter 13 (GitOps) problem — the same layered-debugging habit from chapter 14.6, now on a cluster that actually matters.
