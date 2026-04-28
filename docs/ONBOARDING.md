# Service Onboarding Guide

This document is for application teams adding a new microservice to the Sentic platform. It explains
the delivery model, what you own, what this repo owns, and the exact steps to get your service
running under Argo CD.

## Delivery Model Overview

Sentic uses a **Hybrid GitOps** model (see [ADR-001](adr/ADR-001-SERVICE-DELIVERY-MODEL.md)):

- Your service repo owns its code, Dockerfile, CI pipeline, and Kubernetes manifests.
- This repo (`sentic-infra`) owns a single Argo CD `Application` CR that points Argo at your repo.
- Argo CD pulls your manifests and reconciles them into the cluster. Your CI pipeline never touches
  the cluster directly.

```
┌─────────────────────────┐        PR / tag        ┌──────────────────────────────┐
│   sentic-news-ingester  │ ─────────────────────▶ │  ghcr.io / docker.io image   │
│   (your repo)           │                        │  registry                    │
│                         │  image tag update PR   └──────────────────────────────┘
│   /deploy/              │ ◀────────────────────────────── CI writes back         │
│     chart/              │                                                        │
│       values-dev.yaml   │                                                        │
└─────────────────────────┘                                                        │
          │ Argo watches                                                            │
          ▼                                                                        │
┌─────────────────────────┐                                                        │
│   sentic-infra          │                                                        │
│   (this repo)           │                                                        │
│   manifests/apps/       │                                                        │
│     ingester.yaml  ─────┼──── points Argo at your repo /deploy/chart ──────────▶│
└─────────────────────────┘
```

## What You Are Responsible For

| Item | Location |
|---|---|
| Application code | `your-repo/` |
| Dockerfile | `your-repo/Dockerfile` |
| Helm chart | `your-repo/deploy/chart/` |
| Environment-specific values | `your-repo/deploy/chart/values-<env>.yaml` |
| CI pipeline (build + image push) | `your-repo/.github/workflows/` |
| Image tag write-back (PR or commit) | `your-repo/.github/workflows/` |

## What sentic-infra Is Responsible For

| Item | Location |
|---|---|
| Argo CD Application CR for your service | `manifests/apps/<service-name>.yaml` |
| AppProject permissions | `manifests/projects/sentic-apps.yaml` (once created) |
| RabbitMQ cluster and queue topology | `manifests/cluster/`, `manifests/topology/` |
| Operators and control plane | `manifests/operators/` |

## Recommended Service Repo Layout

Sentic services use **Helm** for packaging and deployment. Argo CD renders the chart directly from
the service repo — no Helm registry required.

```
sentic-news-ingester/
├── Dockerfile
├── .github/
│   └── workflows/
│       └── ci.yaml          # build, push image, open tag-update PR
├── deploy/
│   └── chart/
│       ├── Chart.yaml
│       ├── values.yaml          # chart defaults (image repo, resource limits, secret names)
│       ├── values-dev.yaml      # dev overrides — CI updates image.tag here via PR
│       └── templates/
│           ├── _helpers.tpl
│           └── deployment.yaml
└── src/
    └── ...
```

### deploy/chart/Chart.yaml

```yaml
apiVersion: v2
name: sentic-<your-service>
description: Helm chart for the Sentic <Your Service> microservice
type: application
version: 0.1.0
appVersion: "0.1.0"
```

### deploy/chart/values.yaml

```yaml
replicaCount: 1

image:
  repository: ghcr.io/ad-1/sentic-<your-service>
  pullPolicy: IfNotPresent
  # Overridden per environment in values-<env>.yaml. CI writes the new tag there via PR.
  tag: ""

# RabbitMQ connection — credentials come from the secret auto-created by the
# RabbitMQ Cluster Operator. Do not hard-code credentials here.
rabbitmq:
  secretName: definition-default-user
  queue: <your-queue-name>

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

### deploy/chart/values-dev.yaml

```yaml
# Dev environment overrides.
# CI updates image.tag here via a PR on every successful image push.
image:
  tag: "latest"
```

### deploy/chart/templates/deployment.yaml (minimal example)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "sentic-<your-service>.fullname" . }}
  namespace: sentic
  labels:
    {{- include "sentic-<your-service>.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "sentic-<your-service>.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "sentic-<your-service>.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: sentic-<your-service>
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          env:
            - name: RABBITMQ_HOST
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.rabbitmq.secretName }}
                  key: host
            - name: RABBITMQ_PORT
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.rabbitmq.secretName }}
                  key: port
            - name: RABBITMQ_USERNAME
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.rabbitmq.secretName }}
                  key: username
            - name: RABBITMQ_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.rabbitmq.secretName }}
                  key: password
            - name: RABBITMQ_QUEUE
              value: {{ .Values.rabbitmq.queue | quote }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

## Connecting to RabbitMQ

The `RabbitmqCluster` in namespace `sentic` is named `definition`. The Cluster Operator
automatically creates a secret `definition-default-user` in the same namespace with the following
keys:

| Key | Value |
|---|---|
| `username` | auto-generated |
| `password` | auto-generated |
| `host` | `definition.sentic.svc.cluster.local` |
| `port` | `5672` |

Reference this secret in your Deployment directly. Do not hard-code credentials.

## Adding Your Service to sentic-infra

Once your service repo is ready, add an Argo CD Application CR to this repo. No other changes to
this repo are needed.

1. Create `manifests/apps/<your-service>.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sentic-<your-service>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "20"
spec:
  project: default
  source:
    repoURL: https://github.com/ad-1/<your-service>
    targetRevision: main
    path: deploy/chart
    helm:
      valueFiles:
        - values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: sentic
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 10m
```

2. Open a PR against `sentic-infra`. Once merged, Argo CD detects the new Application and begins
   reconciling your service into the cluster automatically.

### Sync Wave

Use wave `20` for all service Applications. This places them after:

| Wave | What Runs First |
|---|---|
| 1–3 | Operators (cert-manager, RabbitMQ operators) |
| 5 | RabbitmqCluster |
| 10 | Queue topology |
| **20** | **Your service** |

This guarantees the broker and queues your service depends on are ready before your pods start.

## CI Pipeline: Image Tag Update Flow

Your CI pipeline should never call `kubectl`. Instead, after a successful image push, call the
reusable workflow defined in `sentic-infra`. It is defined once here and shared by all service
teams — you do not need to implement or maintain the tag-update logic yourself.

The workflow lives at:

```
sentic-infra/.github/workflows/update-image-tag.yaml
```

### How It Works

1. Your service CI builds and pushes the Docker image.
2. Your CI calls the reusable workflow, passing the service name, image, and new tag.
3. The reusable workflow opens a PR in your service repo updating `newTag` in your overlay.
4. Once the PR is merged, Argo CD detects the change and rolls out the new image automatically.

No `kubectl`, no cluster credentials, no manual steps.

### Calling the Reusable Workflow From Your Service CI

Add a job to your service repo's `.github/workflows/ci.yaml`:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image-tag: ${{ steps.meta.outputs.version }}
    steps:
      - uses: actions/checkout@v4

      - name: Extract image metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/ad-1/sentic-<your-service>
          tags: |
            type=sha,format=short

      - name: Build and push image
        uses: docker/build-push-action@v5
        with:
          push: true
          tags: ${{ steps.meta.outputs.tags }}

  update-tag:
    needs: build
    uses: ad-1/sentic-infra/.github/workflows/update-image-tag.yaml@main
    with:
      service-name: sentic-<your-service>
      image: ghcr.io/ad-1/sentic-<your-service>
      tag: ${{ needs.build.outputs.image-tag }}
    secrets:
      token: ${{ secrets.GITHUB_TOKEN }}
```

### What the Reusable Workflow Does

- Checks out your service repo.
- Validates that `deploy/chart/values-dev.yaml` exists and has an `image.tag` entry.
- Rewrites `image.tag` to the new value.
- Opens a PR titled `deploy(sentic-<your-service>): <tag>` with a standard description.

Any improvements made to the workflow in `sentic-infra` propagate to all service repos
automatically on their next CI run — no changes needed in individual service repos.

### Future: Argo CD Image Updater

As an alternative to the CI write-back approach above, [Argo CD Image Updater](https://argocd-image-updater.readthedocs.io/)
can watch your image registry directly and write tag updates back to Git without any CI
involvement. This is a natural upgrade path once the number of services grows and CI-driven
write-back becomes harder to coordinate. It would be deployed as an additional operator in this
repo.

Argo CD picks up the merged tag change and rolls out the new image automatically.

## Secrets and Credentials

- RabbitMQ credentials are injected via the `definition-default-user` secret (see above).
- Any additional secrets (API keys, external service credentials) must be provisioned separately.
  Do not commit secret values to Git. Preferred approach: sealed-secrets or external-secrets
  operator (to be documented when adopted).

## Validation After Deployment

```bash
# Check Argo CD application health
kubectl -n argocd get app sentic-<your-service>

# Check pods in sentic namespace
kubectl -n sentic get pods -l app=sentic-<your-service>

# Tail logs
kubectl -n sentic logs -l app=sentic-<your-service> -f --tail=50
```

## Getting Help

- Platform questions: refer to [../README.md](../README.md) for cluster bootstrap and repave
  behavior.
- RabbitMQ queue topology: refer to `manifests/topology/queues.yaml`.
- Architecture decisions: refer to [`docs/adr/`](adr/).
