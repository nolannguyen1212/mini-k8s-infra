# 8. Lab: deploy two real apps

Two minimal services, on purpose small enough to type in five minutes, but wired exactly like a real backend service: health endpoints, config from the cluster (not baked into the image), resource limits, probes, a Service, and one Ingress in front of both. This is the concrete implementation of chapter 5's config.yaml vs .env pattern.

Layout built in this chapter:

```
apps/
  go-app/
    main.go
    config.yaml
    Dockerfile
    k8s/
      configmap.yaml
      deployment.yaml
      service.yaml
  js-app/
    server.js
    package.json
    .env.example
    Dockerfile
    k8s/
      secret.yaml
      configmap.yaml
      deployment.yaml
      service.yaml
  ingress.yaml
```

## 8.1 go-app: config.yaml mounted as a file

```sh
mkdir -p apps/go-app/k8s
```

`apps/go-app/main.go`:

```go
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Server struct {
		Port int `yaml:"port"`
	} `yaml:"server"`
	LogLevel  string `yaml:"log_level"`
	FeatureX  bool   `yaml:"feature_x"`
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func main() {
	configPath := os.Getenv("CONFIG_PATH")
	if configPath == "" {
		configPath = "config.yaml"
	}
	cfg, err := loadConfig(configPath)
	if err != nil {
		log.Fatalf("failed to load config from %s: %v", configPath, err)
	}
	log.Printf("loaded config: log_level=%s feature_x=%v port=%d",
		cfg.LogLevel, cfg.FeatureX, cfg.Server.Port)

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	http.HandleFunc("/config", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(cfg)
	})

	addr := ":" + os.Getenv("PORT")
	if os.Getenv("PORT") == "" {
		addr = ":8080"
	}
	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
```

`apps/go-app/config.yaml` (local dev default, baked into the image as a fallback only, never the value used in the cluster):

```yaml
server:
  port: 8080
log_level: info
feature_x: false
```

`apps/go-app/Dockerfile`:

```dockerfile
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY main.go go.mod* ./
RUN go mod init go-app 2>/dev/null; go mod tidy; go build -o /app main.go

FROM alpine:3.19
COPY --from=build /app /app
COPY config.yaml /config.yaml
ENV CONFIG_PATH=/config.yaml
EXPOSE 8080
ENTRYPOINT ["/app"]
```

Build and load into kind (kind cannot pull local images, they must be explicitly loaded):

```sh
docker build -t go-app:1.0.0 apps/go-app
kind load docker-image go-app:1.0.0 --name lab
```

`apps/go-app/k8s/configmap.yaml`, this is what overrides the image's baked-in default at deploy time:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: go-app-config
data:
  config.yaml: |
    server:
      port: 8080
    log_level: debug
    feature_x: true
```

`apps/go-app/k8s/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-app
spec:
  replicas: 2
  selector:
    matchLabels: { app: go-app }
  template:
    metadata:
      labels: { app: go-app }
    spec:
      containers:
        - name: go-app
          image: go-app:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: CONFIG_PATH
              value: /etc/go-app/config.yaml
          volumeMounts:
            - name: config
              mountPath: /etc/go-app
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits:   { cpu: 250m, memory: 128Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: go-app-config
```

`apps/go-app/k8s/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: go-app
spec:
  selector: { app: go-app }
  ports:
    - port: 80
      targetPort: 8080
```

```sh
kubectl apply -f apps/go-app/k8s/configmap.yaml
kubectl apply -f apps/go-app/k8s/deployment.yaml
kubectl apply -f apps/go-app/k8s/service.yaml
kubectl rollout status deployment/go-app
kubectl port-forward svc/go-app 8080:80 &
curl localhost:8080/healthz
curl localhost:8080/config   # confirm log_level is "debug" and feature_x is true, proving the ConfigMap won, not the baked-in default
```

## 8.2 js-app: .env values injected as environment variables

```sh
mkdir -p apps/js-app/k8s
```

`apps/js-app/server.js`:

```js
const http = require("http");

const port = process.env.PORT || 8080;
const logLevel = process.env.LOG_LEVEL || "info";
const apiKey = process.env.API_KEY || "";

console.log(`starting js-app, log_level=${logLevel}, api_key_set=${Boolean(apiKey)}`);

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200);
    res.end("ok");
    return;
  }
  if (req.url === "/config") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ logLevel, apiKeySet: Boolean(apiKey) }));
    return;
  }
  res.writeHead(404);
  res.end();
});

server.listen(port, () => console.log(`listening on ${port}`));
```

`apps/js-app/package.json`:

```json
{
  "name": "js-app",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" }
}
```

`apps/js-app/.env.example`, committed to git as documentation of what variables exist, real values never committed:

```
PORT=8080
LOG_LEVEL=info
API_KEY=changeme
```

`apps/js-app/Dockerfile`:

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev || true
COPY server.js ./
EXPOSE 8080
CMD ["node", "server.js"]
```

```sh
docker build -t js-app:1.0.0 apps/js-app
kind load docker-image js-app:1.0.0 --name lab
```

`apps/js-app/k8s/configmap.yaml`, the non-sensitive half of `.env`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: js-app-config
data:
  LOG_LEVEL: debug
```

`apps/js-app/k8s/secret.yaml`, the sensitive half of `.env`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: js-app-secret
type: Opaque
stringData:
  API_KEY: local-dev-key-123
```

`apps/js-app/k8s/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: js-app
spec:
  replicas: 2
  selector:
    matchLabels: { app: js-app }
  template:
    metadata:
      labels: { app: js-app }
    spec:
      containers:
        - name: js-app
          image: js-app:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef: { name: js-app-config }
            - secretRef: { name: js-app-secret }
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits:   { cpu: 250m, memory: 128Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
            periodSeconds: 10
```

`apps/js-app/k8s/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: js-app
spec:
  selector: { app: js-app }
  ports:
    - port: 80
      targetPort: 8080
```

```sh
kubectl apply -f apps/js-app/k8s/configmap.yaml
kubectl apply -f apps/js-app/k8s/secret.yaml
kubectl apply -f apps/js-app/k8s/deployment.yaml
kubectl apply -f apps/js-app/k8s/service.yaml
kubectl rollout status deployment/js-app
kubectl port-forward svc/js-app 8081:80 &
curl localhost:8081/healthz
curl localhost:8081/config   # confirm logLevel debug and apiKeySet true
```

## 8.3 One Ingress in front of both

Requires ingress-nginx installed and the kind cluster created with `extraPortMappings` (chapter 7.3).

`apps/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: apps
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - host: lab.local
      http:
        paths:
          - path: /go(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service: { name: go-app, port: { number: 80 } }
          - path: /js(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service: { name: js-app, port: { number: 80 } }
```

```sh
kubectl apply -f apps/ingress.yaml
curl http://lab.local/go/healthz
curl http://lab.local/js/healthz
```

## 8.4 Verify the config split end to end

```sh
kubectl exec deploy/go-app -- cat /etc/go-app/config.yaml     # file mount, structured yaml
kubectl exec deploy/js-app -- printenv | grep -E "LOG_LEVEL|API_KEY"   # env vars, flat key/value

kubectl edit configmap go-app-config          # bump log_level, no restart needed, file updates in place
kubectl edit configmap js-app-config           # bump LOG_LEVEL, then:
kubectl rollout restart deployment/js-app        # required, env vars only refresh on new Pod
```

This confirms in practice what chapter 5.6 states: the file-mounted ConfigMap updates live, the env-injected one needs a rollout.

## 8.5 Cleanup

```sh
kubectl delete -f apps/ingress.yaml
kubectl delete -f apps/go-app/k8s -f apps/js-app/k8s
```
