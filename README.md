# Sentic Infrastructure

GitOps-managed RabbitMQ infrastructure for Sentic, designed for repeatable rebuilds from source control (Phoenix/DR model).

## What This Repository Manages

- Argo CD control-plane bootstrap and app-of-apps orchestration.
- Operator layer:
  - cert-manager
  - RabbitMQ Cluster Operator
  - RabbitMQ Messaging Topology Operator
- Workload layer:
  - RabbitmqCluster in namespace sentic
  - Queue topology (Queue CRs) in namespace sentic

## GitOps Topology

### Root Argo CD Application

The repository uses one root Argo CD Application at argocd/application.yaml.

- bootstrap applies argocd/application.yaml.
- The root app points to manifests/ with recurse: true.
- Sync waves enforce ordering:

| Wave | Resource |
| --- | --- |
| 1 | cert-manager Application |
| 2 | rabbitmq-cluster-operator Application |
| 3 | rabbitmq-messaging-topology-operator Application |
| 5 | RabbitmqCluster (manifests/cluster/definition.yaml) |
| 10 | Queue resources (manifests/topology/queues.yaml) |

### Operator App Sources

- manifests/operators/cert-manager.yaml:
  - Uses Helm chart from https://charts.jetstack.io.
- manifests/operators/rabbitmq-cluster-operator.yaml:
  - Uses upstream repo path config/installation.
  - Pins operator image tag via kustomize.images.
- manifests/operators/rabbitmq-messaging-topology-operator.yaml:
  - Uses upstream repo path config/installation.
  - Pins operator image tag via kustomize.images.
  - Removes Namespace/rabbitmq-system from this app using a kustomize delete patch so only one app owns that Namespace.
  - Ignores webhook caBundle drift injected by cert-manager.

## Namespace Architecture

- argocd: Argo CD control plane and repo credentials secret.
- cert-manager: cert-manager components.
- rabbitmq-system: RabbitMQ operator deployments and webhooks.
- sentic: RabbitmqCluster and Queue CRs.

bootstrap pre-creates required namespaces to reduce race conditions during first sync.

## Bootstrap (Fresh Cluster)

### Prerequisites

1. A running Kubernetes context (default is minikube; override with KUBE_CTX=<context>).
2. kubectl configured for that context.
3. A GitHub PAT with read access to this repository.
4. PAT provided via either:
   - environment variable: export GITHUB_PAT=...
   - file: ~/.github_pat

### Command

```bash
make bootstrap
```

### What bootstrap Does

1. Validates GITHUB_PAT is available.
2. Creates namespaces (argocd, cert-manager, rabbitmq-system, sentic) idempotently.
3. Installs/updates Argo CD manifests in argocd using server-side apply.
4. Waits for Argo CD CRDs and argocd-server readiness.
5. Creates/updates the repo-creds secret in argocd atomically (including required Argo CD label).
6. Applies the root app manifest at argocd/application.yaml.

### Expected First-Sync Behavior

Transient warning states may appear while CRDs, webhooks, and controllers settle. With sync waves and retries, apps should converge to Synced and Healthy after startup.

## Day-2 Operations

### Common Commands

- make apply
  - Applies manifests/cluster/definition.yaml and manifests/topology/queues.yaml.
- make validate
  - Runs readiness, status, image checks, and pod-health checks.
- make smoke-test
  - Verifies publish and consume path through RabbitMQ management API.
- make setup-validate
  - One-shot flow for preflight + bootstrap + apply + validation + smoke test.
- make status
  - Shows RabbitmqCluster and Queue status.
- make wait
  - Waits for broker pod readiness.
- make port-forward
  - Opens Argo CD and RabbitMQ local tunnels.

## Repave Behavior (Important)

### Does repave blow away Argo CD?

No. This is expected behavior: repave does not delete the Argo CD control plane namespace.

What repave does:

1. validate-operator-tags preflight.
2. nuke, which:
   - Deletes all Argo CD Application resources in namespace argocd (cascade foreground).
   - Deletes RabbitMQ CRs and PVCs in namespace sentic.
   - Deletes namespaces cert-manager and rabbitmq-system.
   - Runs bootstrap to rebuild from Git.
3. wait-argocd-operator-apps until operator apps are Synced and Healthy.
4. Re-applies cluster and topology manifests.
5. Runs validate and smoke-test.

What repave does not do:

- It does not delete namespace argocd.
- It does not explicitly uninstall Argo CD core resources; bootstrap re-applies them idempotently.

So seeing Argo CD remain present across repave is correct and by design.

### repave-hard

repave-hard is an alias for repave.

## Drift Controls and OutOfSync Guardrails

The repository intentionally includes drift protections for common GitOps edge cases:

- CPU quantity canonicalization in manifests/cluster/definition.yaml:
  - CPU limit uses "1" (canonical) to avoid 1 vs 1000m diffs.
- Messaging topology webhook caBundle ignore in manifests/operators/rabbitmq-messaging-topology-operator.yaml:
  - Prevents perpetual OutOfSync from cert-manager injection.
- Single-owner Namespace strategy for rabbitmq-system:
  - topology app deletes Namespace/rabbitmq-system from its rendered output.
  - cluster-operator app remains the owner.
- Operator image tag safety:
  - Release tags must not include v prefix.
  - Argo kustomize image overrides use upstream-specific image keys.

## DR / Phoenix Runbook (Minimal)

For a fresh cluster:

1. Confirm correct Kubernetes context.
2. Confirm GITHUB_PAT is available.
3. Run make bootstrap.
4. Run make apply.
5. Verify with make validate.
6. Optional end-to-end verification: make smoke-test.

For a destructive clean-room rebuild:

```bash
make repave
```

## Repository Layout

- argocd/application.yaml
  - Root Argo CD Application (recurses manifests/).
- manifests/operators/
  - Child Argo CD Applications for cert-manager and RabbitMQ operators.
- manifests/cluster/definition.yaml
  - RabbitmqCluster custom resource.
- manifests/topology/queues.yaml
  - Queue custom resources.
- scripts/rabbitmq_smoke_test.sh
  - Publish/consume smoke test.
- Makefile
  - Bootstrap, validation, repave, and helper targets.
