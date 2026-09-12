# 3. Networking

## 3.1 The problem

Pods are ephemeral, their IPs change every time they are recreated. You cannot hardcode a Pod IP anywhere. Service solves this by giving a stable virtual IP and DNS name in front of a changing set of Pods.

## 3.2 Service

A Service selects Pods by label and load balances traffic across them.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: miniflux
spec:
  selector:
    app: miniflux        # must match Pod labels, not Deployment name
  ports:
    - port: 80           # port the Service listens on
      targetPort: 8080     # port the container listens on
  type: ClusterIP          # default
```

How it works under the hood: `kube-proxy` on every Node watches Services/Endpoints and programs iptables (or ipvs) rules so that traffic to the Service's virtual IP gets DNAT'd to one of the backing Pod IPs. There is no actual process listening on the Service IP, it is pure netfilter rewriting.

```sh
kubectl get endpoints miniflux     # the actual Pod IPs currently backing this Service
kubectl describe svc miniflux
```

If `Endpoints` is empty, the selector does not match any Pod, or matched Pods are not Ready (see readinessProbe in chapter 2). This is the most common "my Service does not work" cause.

### Service types

| Type | Use case | Behavior |
|------|----------|----------|
| ClusterIP | internal service to service traffic | virtual IP reachable only inside the cluster |
| NodePort | quick local access | opens the same port (30000-32767) on every Node |
| LoadBalancer | external access on cloud providers | provisions a cloud LB, unsupported bare-metal/kind without extra addon |
| ExternalName | alias to external DNS | returns a CNAME, no proxying, no selector |

```yaml
apiVersion: v1
kind: Service
metadata:
  name: miniflux-nodeport
spec:
  selector: { app: miniflux }
  type: NodePort
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 30080
```

```sh
kubectl port-forward svc/miniflux 8080:80   # fastest way to reach a ClusterIP Service from your laptop
curl localhost:8080
```

### Headless Service

`clusterIP: None` disables load balancing and virtual IP entirely, DNS returns the individual Pod IPs directly. Required for StatefulSet so each replica gets its own stable DNS name (see chapter 2.3).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  clusterIP: None
  selector: { app: redis }
  ports:
    - port: 6379
```

## 3.3 Cluster DNS

CoreDNS runs in `kube-system` and resolves Service names automatically. Full form:

```
<service>.<namespace>.svc.cluster.local
```

From any Pod in the same namespace, just `miniflux` resolves. From a different namespace, `miniflux.other-namespace` resolves, and this is exactly how miniflux (in its own namespace) reaches Postgres (in a separate `platform` namespace) by its full name, `postgres.platform.svc.cluster.local`, never by Pod IP.

```sh
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup miniflux
```

## 3.4 Ingress

Service exposes one app on one port. Ingress is an HTTP(S) layer 7 router in front of multiple Services, doing host/path based routing, TLS termination, all through one entrypoint.

Ingress is only a spec, it does nothing by itself. You need an Ingress controller (a Pod running a reverse proxy like NGINX) that watches Ingress objects and configures itself accordingly.

Install an Ingress controller on kind:

```sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

kind needs `extraPortMappings` in its cluster config for the Ingress controller's ports to actually reach your machine, covered in chapter 7.

Ingress object routing to miniflux:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: apps
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: miniflux.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: miniflux
                port:
                  number: 80
```

```sh
echo "127.0.0.1 miniflux.local" | sudo tee -a /etc/hosts
curl http://miniflux.local/healthcheck
kubectl describe ingress apps
```

Only `miniflux` ever gets an Ingress. Postgres, Redis, Kafka, and MinIO are not HTTP services and have no business being reachable from outside the cluster at all, they stay `ClusterIP`/headless-only for their entire life (chapter 8 keeps this rule, chapter 15 keeps it on the VPS too).

## 3.5 NetworkPolicy

By default, every Pod can talk to every other Pod in the cluster, no restrictions. NetworkPolicy is an allowlist: once any policy selects a Pod, all traffic not explicitly allowed is denied for that Pod. Requires a CNI plugin that enforces policies (kind's default kindnet does not, you would need Calico installed for this to actually take effect, but the spec is worth knowing regardless).

Postgres and miniflux end up in separate namespaces later (`platform` and `miniflux` respectively, chapter 14), so this example uses `namespaceSelector` from the start rather than teaching a same-namespace `podSelector` version first and a cross-namespace one later:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-allow-from-miniflux
  namespace: platform
spec:
  podSelector:
    matchLabels: { app: postgres }
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: miniflux }
      ports:
        - port: 5432
```

This says: only Pods running in the namespace literally called `miniflux` may send traffic to Pods labeled `app: postgres` in the `platform` namespace, on port 5432. Everything else to Postgres is dropped, including other Pods inside `platform` itself. `kubernetes.io/metadata.name` is a label Kubernetes stamps onto every Namespace automatically, always equal to the namespace's own name, which is what lets `namespaceSelector` target "the namespace called `miniflux`" without hand-labeling anything. This is the K8s equivalent of a database security group rule. Chapter 8 applies this exact policy for real.

## 3.6 Try it

```sh
kubectl create deployment web --image=nginx:latest
kubectl expose deployment web --port=80 --target-port=80
kubectl get svc web
kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- curl web
kubectl scale deployment web --replicas=0
kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- curl -m 3 web   # observe the failure, no Endpoints left
kubectl delete deployment web svc web
```
