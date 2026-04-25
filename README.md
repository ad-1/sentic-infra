# Sentic Infrastructure

GitOps-managed RabbitMQ infrastructure for Sentic, designed so a fresh cluster can be rebuilt from source control (Phoenix Infrastructure / DR mindset).

## What This Repo Manages

- ArgoCD App-of-Apps orchestration.
- Operator layer:
  - cert-manager
  - RabbitMQ Cluster Operator
  - RabbitMQ Messaging Topology Operator
- Workload layer:
  - `RabbitmqCluster` in namespace `sentic`
  - Queue topology (`Queue` CRs) in namespace `sentic`

## App-of-Apps Topology

There are two ArgoCD entry points in this repo:

1. Seed app (`argocd/application.yaml`, optional/manual):
  - Points at repository root.
  - Excludes `argocd/**` and `infrastructure/operators/**` to avoid ownership conflicts.
  - Can manage workload manifests (for example `definition.yaml` and `topology/`).

2. Root app (`infrastructure/root-app.yaml`, used by `make bootstrap`):
  - Points at `infrastructure/operators`.
  - Manages child ArgoCD Applications for operators.
  - Has automated sync with prune + self-heal + retry.

Operator child Applications use sync waves:

- wave `1`: cert-manager
- wave `2`: rabbitmq-cluster-operator
- wave `3`: rabbitmq-messaging-topology-operator

This ensures cert-manager is healthy before the topology operator starts.

## Namespace Architecture

- `argocd`: ArgoCD control plane + repo credentials secret.
- `cert-manager`: cert-manager components.
- `rabbitmq-system`: RabbitMQ operators.
- `sentic`: RabbitMQ cluster and queue topology.

`make bootstrap` pre-creates all required namespaces, and ArgoCD apps also use `CreateNamespace=true` as a safety net.

## Bootstrap (Fresh Cluster)

### Prerequisites

1. A running Kubernetes context (default `minikube`, override with `KUBE_CTX=<context>`).
2. `kubectl` configured for that cluster.
3. A GitHub PAT with repo read access for this private repository.
4. PAT provided as one of:
  - environment variable: `export GITHUB_PAT=...`
  - file: `~/.github_pat`

### Command

```bash
make bootstrap
```

Quick check before you run it:

```bash
ls ~/.github_pat
```

### What `bootstrap` Does

1. Validates `GITHUB_PAT` is set (fails fast if missing).
2. Creates namespaces (`argocd`, `cert-manager`, `rabbitmq-system`, `sentic`) idempotently.
3. Installs ArgoCD manifests.
4. Waits for ArgoCD CRDs and API deployment readiness.
5. Creates/updates the repo credentials secret (`repo-creds`) in `argocd`:
  - Secret is rendered in-memory with `--dry-run=client -o yaml`.
  - Required ArgoCD label is added in-memory with `kubectl label --local`.
  - Final manifest is applied in one atomic pipe.
  - No PAT file is written to the repo.
6. Applies `infrastructure/root-app.yaml`.

### Expected Bootstrap Behavior

During the first few minutes, you may see transient warnings or errors while operators and webhooks are coming up, for example webhook call failures.

This is expected during a cold start. The ArgoCD Applications use sync waves and retry backoff, so the system should self-heal to green within roughly 3 to 5 minutes.

## Day-2 Operations

### Deploy/Apply Workloads

```bash
make apply
```

Applies:

- `definition.yaml` (RabbitmqCluster)
- `topology/queues.yaml` (Queue CRs)

### Repave (Preserve Data)

```bash
make repave
```

Flow:

1. Deletes queue topology and RabbitmqCluster definitions.
2. Re-applies definitions.
3. Waits for broker readiness.
4. Prints generated credentials and AMQP URL.

Notes:

- PVCs are not deleted, so persistent broker data is preserved.

### Repave Hard (Blow Everything Away)

```bash
make repave-hard
```

Flow:

1. Deletes queue topology resources.
2. Deletes all `RabbitmqCluster` resources in namespace `sentic`.
3. Deletes all PVCs in namespace `sentic`.
4. Re-applies workload manifests.

This is destructive and wipes broker state.

### Runtime Helpers

- `make status` - quick RabbitMQ/Queue status.
- `make wait` - blocks until broker pod is Ready.
- `make logs` - tails broker logs.
- `make port-forward` - generic forwarding helper (RabbitMQ default).
- `make username`, `make password`, `make amqp-url` - credential helpers.

Port-forward options:

```bash
make port-forward                  # RabbitMQ (AMQP + UI)
make port-forward TARGET=argocd    # ArgoCD UI
make port-forward TARGET=both      # RabbitMQ + ArgoCD
```

### ArgoCD UI After Bootstrap

Once `make bootstrap` finishes, you can inspect the cascading sync in the ArgoCD UI.

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Open a tunnel to the UI:

```bash
make port-forward TARGET=argocd
```

Then browse to `https://localhost:8080`.

## Production Readiness Notes

- Operator versions are pinned in `infrastructure/operators/*.yaml`.
- All ArgoCD Applications use automated sync with prune + self-heal.
- Retry backoff is configured to handle transient sync/startup races.
- Topology operator app ignores webhook `caBundle` drift injected by cert-manager to prevent perpetual OutOfSync loops.

## DR / Phoenix Recovery Runbook (Minimal)

For a brand-new cluster:

1. Ensure Kubernetes context is correct.
2. Ensure PAT is available (`GITHUB_PAT` or `~/.github_pat`).
3. Run `make bootstrap`.
4. Run `make apply` (if workload manifests are not already being applied by ArgoCD in your chosen model).
5. Verify with `make status` and `make wait`.
6. Use `make port-forward` for local validation.

If you want a full clean-room DR rehearsal on Minikube:

```bash
minikube delete
minikube start
make bootstrap
```

## Repository Layout

- `argocd/application.yaml` - optional seed app manifest.
- `infrastructure/root-app.yaml` - root app that manages operator child apps.
- `infrastructure/operators/` - operator ArgoCD Application manifests.
- `definition.yaml` - RabbitmqCluster custom resource.
- `topology/queues.yaml` - RabbitMQ queue topology custom resources.
- `Makefile` - bootstrap, deploy, repave, and helper targets.