# 6. Security and RBAC

## 6.1 ServiceAccount

Every Pod runs as a ServiceAccount, `default` in its namespace if you do not specify one. This identity is what the Pod uses to talk to the Kubernetes API itself (not your app's business logic API, the Kubernetes control plane API). Most simple backend services never call the K8s API and do not need any permissions, but anything that does (a controller, an operator, a CI job running `kubectl`, ArgoCD's own components) authenticates as a ServiceAccount.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: miniflux
```

```yaml
spec:
  serviceAccountName: miniflux     # set on the Pod template, defaults to "default" if omitted
  containers: [...]
```

A token for the ServiceAccount is automatically mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token` inside every Pod unless `automountServiceAccountToken: false` is set. If your app never calls the K8s API, disable this, it is an unused credential otherwise sitting in the filesystem — miniflux itself never calls the K8s API, so its ServiceAccount only exists here for the RBAC example below, in practice it would set this to `false`.

ServiceAccount identity is not just for app code: chapter 13's ArgoCD is a concrete example of the same idea applied to platform tooling — its `repo-server`, `application-controller`, and `server` components each run as their own ServiceAccount, each with its own least-privilege RBAC grant, not one shared identity for "ArgoCD" as a whole.

## 6.2 Role, ClusterRole, RoleBinding, ClusterRoleBinding

RBAC answers "who can do what to which objects." Two axes: scope (namespaced Role vs cluster-wide ClusterRole) and the binding that actually grants it to a subject (user, group, or ServiceAccount).

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: miniflux
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: miniflux-pod-reader
  namespace: miniflux
subjects:
  - kind: ServiceAccount
    name: miniflux
    namespace: miniflux
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

`ClusterRole`/`ClusterRoleBinding` are identical in shape but apply cluster-wide (needed for cluster-scoped resources like `nodes`, or to grant the same Role across every namespace).

```sh
kubectl apply -f role.yaml -f rolebinding.yaml
kubectl auth can-i list pods --as=system:serviceaccount:miniflux:miniflux -n miniflux
kubectl auth can-i delete deployments --as=system:serviceaccount:miniflux:miniflux -n miniflux
```

`kubectl auth can-i` is the tool for verifying RBAC before you discover it the hard way in a 403 log line.

Principle of least privilege in practice: start with zero permissions (do not attach any Role), add exactly the verbs/resources an app's own code path needs, nothing broader. `cluster-admin` bound to an app ServiceAccount is a real, common misconfiguration, treat it as a finding if you see it.

## 6.3 SecurityContext

Controls the Linux-level privileges a container runs with, set at Pod level (applies to all containers) or container level (overrides Pod level for that container).

```yaml
spec:
  securityContext:              # Pod level
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
    - name: app
      securityContext:           # container level
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

| Field | What it prevents |
|-------|-------------------|
| `runAsNonRoot` | container process running as root (UID 0) inside the container |
| `readOnlyRootFilesystem` | anything writing to the container's own filesystem, forces explicit volumes for anything that needs to write |
| `allowPrivilegeEscalation: false` | a process gaining more privileges than its parent (setuid binaries, etc) |
| `capabilities.drop: ["ALL"]` | all Linux capabilities beyond the bare minimum, add back only what is proven necessary via `add:` |

This is the checklist a security review looks for on any Pod spec. A stateless HTTP backend service should satisfy every line above with no functional loss in the overwhelming majority of cases.

## 6.4 Try it

```sh
kubectl create namespace rbac-demo
kubectl create serviceaccount viewer -n rbac-demo
kubectl create role pod-reader --verb=get,list,watch --resource=pods -n rbac-demo
kubectl create rolebinding viewer-binding --role=pod-reader --serviceaccount=rbac-demo:viewer -n rbac-demo

kubectl auth can-i list pods --as=system:serviceaccount:rbac-demo:viewer -n rbac-demo
kubectl auth can-i delete pods --as=system:serviceaccount:rbac-demo:viewer -n rbac-demo
kubectl auth can-i list pods --as=system:serviceaccount:rbac-demo:viewer -n default

kubectl delete namespace rbac-demo
```

Notice the last command denies, RoleBinding (not ClusterRoleBinding) only grants inside the namespace it was created in.
