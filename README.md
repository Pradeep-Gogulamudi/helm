# AI Hub — Helm Chart Migration

## Repository Structure

```
helm/
├── app-template/                  # Shared base chart (library-style)
│   ├── Chart.yaml
│   ├── values.yaml                # All defaults live here
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── httproute.yaml         # GKE Gateway API (replaces Ingress)
│       ├── hpa.yaml
│       └── externalsecret.yaml    # GCP Secret Manager via ESO
│
├── apps/
│   ├── hub-api-service/
│   │   ├── Chart.yaml             # depends on app-template
│   │   ├── values.yaml            # base config (all envs)
│   │   ├── values-test.yaml
│   │   ├── values-acc.yaml
│   │   └── values-prod.yaml
│   └── hub-ui/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-test.yaml
│       ├── values-acc.yaml
│       └── values-prod.yaml
│
└── cluster-bootstrap/             # Apply once per cluster, NOT via Helm
    ├── ns.yaml                    # Namespace: ai-hub
    ├── sa.yaml                    # ServiceAccount with Workload Identity
    └── cluster-secret-store.yaml  # ClusterSecretStore → GCP Secret Manager
```

---

## Deploy Commands

### First time (cluster bootstrap — apply once)
```bash
kubectl apply -f cluster-bootstrap/ns.yaml
kubectl apply -f cluster-bootstrap/sa.yaml
kubectl apply -f cluster-bootstrap/cluster-secret-store.yaml
```

### Install / upgrade an app
```bash
# From the app directory, e.g. apps/hub-api-service/
helm dependency update

# Test env
helm upgrade --install hub-api-service . \
  -f values.yaml \
  -f values-test.yaml \
  -n ai-hub

# Acc env
helm upgrade --install hub-api-service . \
  -f values.yaml \
  -f values-acc.yaml \
  -n ai-hub

# Prod env
helm upgrade --install hub-api-service . \
  -f values.yaml \
  -f values-prod.yaml \
  -n ai-hub
```

### Dry-run / template check
```bash
helm template hub-api-service . -f values.yaml -f values-test.yaml -n ai-hub
```

---

## Gateway Architecture

```
Internet
   │
   ▼
GKE Gateway (gke-l7-global-external-managed)
name: product-content-gateway-test
namespace: ingress-gateway
   │
   ├─ HTTPRoute: hub-api-service  →  path: /api  →  Service: hub-api-service:80
   └─ HTTPRoute: hub-ui           →  path: /     →  Service: hub-ui:80
```

> **Important:** Both HTTPRoutes must reference `gatewayNamespace: ingress-gateway`
> (the healthy gateway). Never use `gateway-system` — that gateway is in Error state.

---

## GCP Secret Manager Integration

### Prerequisites
1. ESO (External Secrets Operator) installed in the cluster
2. GCP service account created: `ai-hub@<project>.iam.gserviceaccount.com`
3. GSA bound to KSA via Workload Identity:
   ```bash
   gcloud iam service-accounts add-iam-policy-binding \
     ai-hub@vdxl-test-product-content-01.iam.gserviceaccount.com \
     --role roles/iam.workloadIdentityUser \
     --member "serviceAccount:vdxl-test-product-content-01.svc.id.goog[ai-hub/ai-hub]"
   ```
4. GSA granted Secret Manager access:
   ```bash
   gcloud projects add-iam-policy-binding vdxl-test-product-content-01 \
     --role roles/secretmanager.secretAccessor \
     --member "serviceAccount:ai-hub@vdxl-test-product-content-01.iam.gserviceaccount.com"
   ```

### Adding a secret to an app
In the app's `values-{env}.yaml`:
```yaml
app-template:
  externalSecret:
    enabled: true
    storeName: gcp-cluster-secret-store
    data:
      - secretKey: MY_ENV_VAR        # name in the K8s Secret
        remoteRef:
          key: projects/<project>/secrets/<secret-name>/versions/latest
```

Then mount it in `values.yaml` env block:
```yaml
app-template:
  env:
    - name: MY_ENV_VAR
      valueFrom:
        secretKeyRef:
          name: hub-api-service   # ExternalSecret targetSecret name
          key: MY_ENV_VAR
```

---

## Key Differences from Kustomize Setup

| | Kustomize (old) | Helm (new) |
|---|---|---|
| Routing | HTTPRoute patches per env | `route:` values block per env |
| Secrets | Manual Secret + patch | ExternalSecret → GCP Secret Manager |
| HPA behavior | Defined in hpa.yaml patch | In `autoscaling:` values block |
| Namespace | ns.yaml in kustomization | cluster-bootstrap (apply once) |
| ServiceAccount | sa.yaml in kustomization | cluster-bootstrap + `serviceAccount.name` |
| Image tag | Image patch per env | `image.tag` per env values file |
| Node selector | Hardcoded in deployment | `nodeSelector` in values (overridable) |
