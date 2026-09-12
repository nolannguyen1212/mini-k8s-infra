# 4. Storage

## 4.1 Why this exists

Container filesystems are ephemeral by default, destroyed when the container is removed. Volumes give a Pod a filesystem that survives container restarts (and optionally survives Pod deletion). Most stateless backend services need none of this beyond `emptyDir` for scratch space, but you need to recognize the pattern for anything with a database.

## 4.2 Volume (Pod level, ephemeral)

A `volume` is defined in `spec.volumes` and mounted into one or more containers via `volumeMounts`. Its lifetime is tied to the Pod, not the container: if a container inside the Pod crashes and restarts, an `emptyDir` volume survives; if the Pod itself is deleted, it is gone.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-demo
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo hello > /cache/data && sleep 3600"]
      volumeMounts:
        - name: scratch
          mountPath: /cache
  volumes:
    - name: scratch
      emptyDir: {}
```

Common volume types:

| Type | Use case |
|------|----------|
| `emptyDir` | scratch space, shared dir between containers in same Pod |
| `configMap` | mount config files (see chapter 5) |
| `secret` | mount secret files (see chapter 5) |
| `hostPath` | mount a path from the Node's filesystem, debugging only, avoid in real workloads |
| `persistentVolumeClaim` | durable storage, survives Pod deletion, see below |

## 4.3 PersistentVolume and PersistentVolumeClaim

This is the durable storage abstraction, split in two so app authors and infrastructure stay decoupled:

* **PersistentVolume (PV)**: a piece of real storage (a cloud disk, an NFS share, a local disk), created by whoever manages infrastructure, or dynamically by a StorageClass provisioner. Cluster scoped, not namespaced.
* **PersistentVolumeClaim (PVC)**: a request for storage made by a namespace, "give me 1Gi ReadWriteOnce." Namespaced. Your Pod mounts the PVC, never the PV directly.

```
Pod --mounts--> PVC --binds to--> PV --backed by--> actual disk
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-data
spec:
  accessModes: ["ReadWriteOnce"]   # one Node can mount read/write at a time
  resources:
    requests:
      storage: 1Gi
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: db-demo
spec:
  containers:
    - name: postgres
      image: postgres:16
      env:
        - name: POSTGRES_PASSWORD
          value: dev
      volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: db-data
```

Access modes:

| Mode | Meaning |
|------|---------|
| ReadWriteOnce (RWO) | one Node mounts read/write, most block storage (EBS, local disk) |
| ReadOnlyMany (ROX) | many Nodes mount read only |
| ReadWriteMany (RWX) | many Nodes mount read/write, needs NFS/EFS-like backend |

## 4.4 StorageClass and dynamic provisioning

Instead of an infra person pre-creating PVs by hand, a StorageClass defines a provisioner that creates a PV on demand the moment a PVC references it.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard    # kind ships a default "standard" class
  resources:
    requests:
      storage: 1Gi
```

```sh
kubectl get storageclass
kubectl get pv
kubectl get pvc
```

kind includes `local-path-provisioner` as the default StorageClass, backed by a directory on the kind node's disk. This is enough to practice PVC binding/mounting, it is not meant for anything you care about persisting past `kind delete cluster`.

Chapters 8-9 use exactly this mechanism for real: Postgres gets a PVC by hand in chapter 8, then Redis/Kafka/MinIO get theirs via `volumeClaimTemplates` on a chart's StatefulSet in chapter 9, so a Pod restart never loses data.

## 4.5 Try it

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 500Mi
EOF

kubectl get pvc demo-data
kubectl get pv

kubectl run writer --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"writer","image":"busybox:1.36","command":["sh","-c","echo persisted > /data/file.txt && sleep 3600"],"volumeMounts":[{"name":"v","mountPath":"/data"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"demo-data"}}]}}'

kubectl exec writer -- cat /data/file.txt
kubectl delete pod writer
# recreate the same pod, the file is still there because the PVC survived
```
