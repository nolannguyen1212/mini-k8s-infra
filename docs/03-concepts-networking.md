# 3. Networking

## 3.1 The problem

Pods are ephemeral, their IPs change every time they are recreated. You cannot hardcode a Pod IP anywhere. Service solves this by giving a stable virtual IP and DNS name in front of a changing set of Pods.

## 3.2 Service

A Service selects Pods by label and load balances traffic across them.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: go-app
spec:
  selector:
    app: go-app        # must match Pod labels, not Deployment name
  ports:
    - port: 80           # port the Service listens on
      targetPort: 8080     # port the container listens on
  type: ClusterIP          # default
```

How it works under the hood: `kube-proxy` on every Node watches Services/Endpoints and programs iptables (or ipvs) rules so that traffic to the Service's virtual IP gets DNAT'd to one of the backing Pod IPs. There is no actual process listening on the Service IP, it is pure netfilter rewriting.

```sh
kubectl get endpoints go-app     # the actual Pod IPs currently backing this Service
kubectl describe svc go-app
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
  name: go-app-nodeport
spec:
  selector: { app: go-app }
  type: NodePort
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 30080
```

```sh
kubectl port-forward svc/go-app 8080:80   # fastest way to reach a ClusterIP Service from your laptop
curl localhost:8080
```

### Headless Service

`clusterIP: None` disables load balancing and virtual IP entirely, DNS returns the individual Pod IPs directly. Required for StatefulSet so each replica gets its own stable DNS name (see chapter 2.3).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db
spec:
  clusterIP: None
  selector: { app: db }
  ports:
    - port: 5432
```

## 3.3 Cluster DNS

CoreDNS runs in `kube-system` and resolves Service names automatically. Full form:

```
<service>.<namespace>.svc.cluster.local
```

From any Pod in the same namespace, just `go-app` resolves. From a different namespace, `go-app.other-namespace` resolves. This is how a JS service talks to a Go service: by Service name, never by Pod IP.

```sh
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup go-app
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

Ingress object routing two apps by path:

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
    - host: lab.local
      http:
        paths:
          - path: /go
            pathType: Prefix
            backend:
              service:
                name: go-app
                port:
                  number: 80
          - path: /js
            pathType: Prefix
            backend:
              service:
                name: js-app
                port:
                  number: 80
```

```sh
echo "127.0.0.1 lab.local" | sudo tee -a /etc/hosts
curl http://lab.local/go/healthz
curl http://lab.local/js/healthz
kubectl describe ingress apps
```

## 3.5 NetworkPolicy

By default, every Pod can talk to every other Pod in the cluster, no restrictions. NetworkPolicy is an allowlist: once any policy selects a Pod, all traffic not explicitly allowed is denied for that Pod. Requires a CNI plugin that enforces policies (kind's default kindnet does not, you would need Calico installed for this to actually take effect, but the spec is worth knowing regardless).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: go-app-allow-from-js
spec:
  podSelector:
    matchLabels: { app: go-app }
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels: { app: js-app }
      ports:
        - port: 8080
```

This says: only Pods labeled `app: js-app` may send traffic to Pods labeled `app: go-app` on port 8080. Everything else to go-app is dropped. This is the K8s equivalent of a security group / firewall rule, and it is namespace scoped by default (add `namespaceSelector` to allow cross-namespace).

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
