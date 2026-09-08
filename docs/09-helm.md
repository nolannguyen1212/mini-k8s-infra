# 9. Helm

## 9.1 What problem Helm solves

Chapter 8 has 10+ hand-written YAML files, and every value that differs between dev/staging/prod (replica count, image tag, config values) means editing YAML by hand or maintaining near-duplicate files. Helm is a templating and packaging layer: write the YAML once as a template with placeholders, supply different `values.yaml` per environment, render and apply.

A Helm chart is a directory with a fixed structure:

```
go-app/
  Chart.yaml          # chart metadata: name, version
  values.yaml           # default values, overridable
  templates/             # Go template files that render to k8s YAML
    deployment.yaml
    service.yaml
    configmap.yaml
    _helpers.tpl          # reusable template snippets
```

## 9.2 Build a chart for go-app

```sh
helm create charts/go-app
```

This scaffolds a generic chart with far more than needed (HPA, ingress, serviceaccount templates already stubbed). Strip it down and replace `templates/` and `values.yaml` with the following, purpose-built for chapter 8's go-app.

`charts/go-app/Chart.yaml`:

```yaml
apiVersion: v2
name: go-app
description: go-app backend service
version: 0.1.0
appVersion: "1.0.0"
```

`charts/go-app/values.yaml`, this is the default, dev-like, environment:

```yaml
replicaCount: 2

image:
  repository: go-app
  tag: "1.0.0"
  pullPolicy: IfNotPresent

service:
  port: 80
  targetPort: 8080

resources:
  requests: { cpu: 50m, memory: 32Mi }
  limits:   { cpu: 250m, memory: 128Mi }

config:
  server:
    port: 8080
  log_level: debug
  feature_x: true
```

`charts/go-app/templates/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
data:
  config.yaml: |
{{ toYaml .Values.config | indent 4 }}
```

`charts/go-app/templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: {{ .Release.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.targetPort }}
          env:
            - name: CONFIG_PATH
              value: /etc/go-app/config.yaml
          volumeMounts:
            - name: config
              mountPath: /etc/go-app
          resources:
{{ toYaml .Values.resources | indent 12 }}
          readinessProbe:
            httpGet: { path: /healthz, port: {{ .Values.service.targetPort }} }
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: {{ .Values.service.targetPort }} }
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: {{ .Release.Name }}-config
```

`charts/go-app/templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
```

Delete the scaffolded `_helpers.tpl`/`serviceaccount.yaml`/`hpa.yaml`/`ingress.yaml`/`tests/` if you did `helm create` and want to keep the chart minimal for now, or leave them, unused templates render nothing extra as long as nothing references them.

## 9.3 Render, diff, install

```sh
helm template go-app charts/go-app                  # render to plain YAML, read it before trusting it
helm lint charts/go-app                                # catch template/schema mistakes
helm install go-app charts/go-app                       # install into the cluster
helm list
helm get values go-app                                    # what values this release actually used
kubectl get deployment go-app
```

`helm template` is the command to run every single time you change a template, it is pure client-side rendering, zero cluster interaction, the fastest feedback loop for catching a broken indent or a wrong field name.

## 9.4 Per-environment values

`charts/go-app/values-prod.yaml`:

```yaml
replicaCount: 5
image:
  tag: "1.2.0"
config:
  log_level: warn
  feature_x: false
resources:
  requests: { cpu: 100m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 256Mi }
```

```sh
helm install go-app charts/go-app -f charts/go-app/values-prod.yaml
# or on an existing release
helm upgrade go-app charts/go-app -f charts/go-app/values-prod.yaml
helm diff upgrade go-app charts/go-app -f charts/go-app/values-prod.yaml   # requires helm-diff plugin, shows exact changes before applying
```

`values.yaml` is the base, `-f` files layer on top and override matching keys, later `-f` flags win over earlier ones, `--set key=value` wins over all files. This layering is the entire mechanism behind "same chart, different environment."

## 9.5 Upgrade, rollback, uninstall

```sh
helm upgrade go-app charts/go-app --set image.tag=1.1.0
helm history go-app
helm rollback go-app 1
helm uninstall go-app
```

Every `helm upgrade` creates a new numbered revision, `helm rollback <release> <revision>` re-applies that revision's exact rendered manifests, mirroring `kubectl rollout undo` from chapter 2 but at the whole-chart level instead of one Deployment.

## 9.6 Repeat for js-app

Same structure, `charts/js-app/`, with `values.yaml` holding a `configData` map (rendered as a ConfigMap for `LOG_LEVEL`) and a `secretData` map (rendered as a Secret for `API_KEY`), consumed via `envFrom` in the Deployment template exactly as in chapter 8.2. Building this chart yourself, from the pattern above, is the actual exercise, do not skip it, the repetition is what makes the ConfigMap+Secret+envFrom template shape automatic.

## 9.7 Try it

```sh
helm template charts/go-app --set replicaCount=1 --set config.log_level=trace | less
helm install go-app charts/go-app
kubectl get all -l app=go-app
helm upgrade go-app charts/go-app --set replicaCount=4
kubectl get deployment go-app -o jsonpath='{.spec.replicas}'
helm uninstall go-app
```
