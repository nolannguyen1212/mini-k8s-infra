# 2. Workloads

Workload objects are controllers that manage Pods for you. You never manage Pods directly in production, you manage the controller and it manages Pods.

## 2.1 ReplicaSet

Guarantees N identical Pods are running, matched by `selector.matchLabels`. You almost never write a ReplicaSet directly, Deployment creates and owns one for you. Worth knowing it exists because `kubectl get rs` shows it and explains where Pods actually come from.

```
Deployment  ->  owns  ->  ReplicaSet  ->  owns  ->  Pod(s)
```

## 2.2 Deployment

The controller for stateless workloads. Handles rolling updates, rollback, and scaling.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: go-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1   # at most 1 pod down during rollout
      maxSurge: 1          # at most 1 extra pod created during rollout
  template:                # this is a full Pod spec, embedded
    metadata:
      labels:
        app: go-app
    spec:
      containers:
        - name: go-app
          image: go-app:1.0.0
          ports:
            - containerPort: 8080
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 10
            periodSeconds: 10
```

Key mechanics:

* `selector.matchLabels` must match `template.metadata.labels`. This is how the Deployment finds "its" Pods. Mismatch is a very common copy-paste bug.
* Rolling update: when you `kubectl apply` a changed image, the Deployment creates a *new* ReplicaSet with the new template, scales it up gradually while scaling the old ReplicaSet down, respecting `maxUnavailable`/`maxSurge`. Old ReplicaSets are kept (scaled to 0) for rollback.
* `readinessProbe` controls whether a Pod receives traffic from a Service (see chapter 3). A Pod can be `Running` but not `Ready`, in which case it is deliberately excluded from load balancing.
* `livenessProbe` controls whether kubelet kills and restarts the container. Get this wrong (too strict) and you get restart loops under normal load, this is a very common production incident.

```sh
kubectl apply -f deployment.yaml
kubectl rollout status deployment/go-app
kubectl set image deployment/go-app go-app=go-app:1.1.0
kubectl rollout history deployment/go-app
kubectl rollout undo deployment/go-app
kubectl scale deployment/go-app --replicas=5
```

## 2.3 StatefulSet

For workloads that need stable identity: stable network name, stable storage, ordered start/stop. Used for databases, queues, anything where "which specific instance" matters (e.g. `postgres-0` is always the same Pod, always gets the same PVC back after a restart).

Differences from Deployment:

* Pods get stable ordinal names: `db-0`, `db-1`, `db-2`, not random suffixes.
* Requires a headless Service (`clusterIP: None`) to give each Pod its own stable DNS name: `db-0.db.default.svc.cluster.local`.
* Each Pod gets its own PersistentVolumeClaim via `volumeClaimTemplates`, and that PVC follows that specific ordinal even across Pod recreation.
* Scale up/down and rollout happen in order (0, then 1, then 2), not all at once.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db          # must match a headless Service name
  replicas: 3
  selector:
    matchLabels: { app: db }
  template:
    metadata:
      labels: { app: db }
    spec:
      containers:
        - name: db
          image: postgres:16
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 1Gi } }
```

As a backend engineer, the practical rule: your own stateless HTTP services are always Deployments. Reach for StatefulSet only for the datastore/broker itself, and in most real setups you would use a managed database instead of running one in-cluster.

## 2.4 DaemonSet

Runs exactly one Pod per Node (or per matching subset of Nodes), automatically added on new Nodes and removed on Node removal. Used for node-level agents: log collectors (Fluent Bit), metrics agents (node-exporter), CNI/CSI plugins.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
spec:
  selector:
    matchLabels: { app: node-agent }
  template:
    metadata:
      labels: { app: node-agent }
    spec:
      containers:
        - name: node-agent
          image: node-agent:1.0
```

You rarely author these as an app developer, but you will see them (`kube-proxy`, CNI plugins) running in `kube-system` on every cluster.

## 2.5 Job and CronJob

Job runs a Pod to completion (not forever). Used for one-off tasks: a DB migration, a batch export.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
spec:
  backoffLimit: 3          # retry attempts on failure
  template:
    spec:
      restartPolicy: Never    # Jobs cannot use Always
      containers:
        - name: migrate
          image: go-app:1.0.0
          command: ["./migrate", "up"]
```

CronJob schedules a Job on a cron expression:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-report
spec:
  schedule: "0 2 * * *"    # 02:00 every day, cluster timezone
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: report
              image: go-app:1.0.0
              command: ["./generate-report"]
```

```sh
kubectl apply -f job.yaml
kubectl get jobs
kubectl logs job/db-migrate
kubectl get cronjobs
kubectl create job --from=cronjob/nightly-report manual-run-1   # trigger once, outside schedule
```

## 2.6 Scheduling: requests, limits, and where Pods land

`resources.requests` is what the scheduler reserves on a Node (a Pod will not be scheduled onto a Node without that much free capacity). `resources.limits` is a hard ceiling enforced by the kernel/runtime: CPU gets throttled past the limit, memory past the limit gets the container OOM-killed.

```yaml
resources:
  requests: { cpu: 100m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 256Mi }
```

`100m` = 0.1 CPU core. Always set both. No requests means the scheduler cannot bin-pack correctly, no limits means one runaway Pod can starve every other Pod on that Node.

Influencing placement:

```yaml
spec:
  nodeSelector:
    disktype: ssd
  affinity:
    podAntiAffinity:      # spread replicas across different nodes
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: { app: go-app }
          topologyKey: kubernetes.io/hostname
  tolerations:              # allow scheduling onto tainted nodes
    - key: "dedicated"
      operator: "Equal"
      value: "batch"
      effect: "NoSchedule"
```

## 2.7 HorizontalPodAutoscaler

Scales `replicas` on a Deployment/StatefulSet based on observed metrics, most commonly CPU percentage of the requested value.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: go-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: go-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

Requires the metrics-server addon to be installed in the cluster (kind does not ship it by default, install separately if you want to test HPA).

```sh
kubectl apply -f hpa.yaml
kubectl get hpa -w
kubectl top pods    # requires metrics-server
```

## 2.8 Try it

```sh
kubectl create deployment demo --image=nginx:latest --replicas=3
kubectl rollout status deployment/demo
kubectl set image deployment/demo nginx=nginx:1.25
kubectl rollout status deployment/demo
kubectl rollout undo deployment/demo
kubectl scale deployment/demo --replicas=1
kubectl delete deployment demo
```

Watch `kubectl get rs -w` in a second terminal while you run the image update, you will see a new ReplicaSet appear and scale up while the old one scales down.
