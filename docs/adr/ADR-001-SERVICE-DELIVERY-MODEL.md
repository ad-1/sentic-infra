# ADR-001: Service Delivery Model — Hybrid GitOps (Manifests in App Repos)

| Field | Value |
|---|---|
| Status | Accepted |
| Date | 2026-04-28 |
| Deciders | Andrew Davies |
| Context | Transition from platform-only infra to multi-microservice delivery |

## Context

The Sentic platform reached a stable state with Argo CD managing operators, a RabbitMQ cluster, and
queue topology via `sentic-infra`. The next step is onboarding application microservices
(e.g., `sentic-news-ingester`, `sentic-analyst`, `sentic-notifier`) into the same GitOps control
plane.

Two standard delivery models exist in the Argo CD ecosystem. A decision was needed before
authoring any service repos.

## Decision Drivers

- The platform already uses a mature app-of-apps root in `argocd/application.yaml` with sync-wave
  ordering. The delivery model for services should extend this naturally.
- Developers should be able to own their deployment manifests alongside their code, matching
  familiar workflows without requiring platform team involvement on every change.
- The cluster should remain fully repavable from Git alone — no out-of-band state.
- CI pipelines for application services must not require `kubectl` or cluster-admin credentials.
- A single location (`sentic-infra`) should provide a complete picture of everything running in the
  cluster.

## Options Considered

### Option A: Pure GitOps (Separate Infra Repo Per Service or Monorepo)

All Kubernetes manifests for all services live in `sentic-infra` (or a dedicated separate repo).
Application repos contain only code and CI. The CI pipeline opens a PR to the infra repo to update
an image tag. Argo CD watches the infra repo for all services.

**Pros:**
- Single repo gives a complete, auditable cluster inventory.
- Strict separation: application developers cannot accidentally affect cluster state.
- Natural fit for organisations with a dedicated platform team owning all cluster manifests.

**Cons:**
- Every deployment requires a cross-repo PR, creating coordination overhead when teams are small.
- Application developers are disconnected from deployment config, making local iteration slower.
- Scaling to many services makes the infra repo unwieldy without strong naming conventions and
  tooling.
- For a small team or solo project, the overhead outweighs the governance benefit.

### Option B: Hybrid GitOps (Manifests in App Repos, Application CRs in sentic-infra) ✅ Chosen

Each service repo contains its own Kubernetes manifests under `deploy/`. The `sentic-infra` repo
contains one Argo CD `Application` CR per service, pointing Argo at that service's repo and path.
Argo CD pulls from both repos and reconciles all resources into the cluster.

**Pros:**
- Developers own their manifests — local Kustomize overlays, resource tuning, and env config live
  next to the code that needs them.
- CI pipelines only need write access to Git, not to the cluster.
- `sentic-infra` remains the single source of truth for _what is registered_ in the cluster
  (all Application CRs live here), while app repos own _how_ each service is deployed.
- Extends the existing app-of-apps pattern without restructuring `sentic-infra`.
- Repave remains fully Git-driven: bootstrap re-applies all Application CRs, which re-pull all
  service manifests.

**Cons:**
- Cluster inventory is distributed: to understand a service's full deployment spec, you must look
  in two repos.
- Image tag updates still require a commit/PR to the service repo's overlay — no different from
  Option A in practice, just scoped to a single repo.

## Decision

**Option B is adopted.**

The existing `sentic-infra` sync-wave model is extended with a wave-20 layer for service
Applications. Each service Application CR is added to `manifests/apps/` in this repo. Service
teams manage their manifests in `deploy/overlays/<env>/` inside their own repos.

## Consequences

### Immediate

- A new directory `manifests/apps/` is added to `sentic-infra` for service Application CRs.
- The root Argo CD Application (`argocd/application.yaml`) already recurses `manifests/` with
  `directory.recurse: true`, so no changes to the root app are needed — new Application CRs in
  `manifests/apps/` are picked up automatically.
- Service repos must follow the layout documented in [../ONBOARDING.md](../ONBOARDING.md).

### Sync Wave Assignment

| Wave | Layer |
|---|---|
| 1–3 | Operators |
| 5 | RabbitmqCluster |
| 10 | Queue topology |
| 20 | Service Applications |

Wave 20 ensures service pods start only after the broker and queues they depend on are healthy.

### Repave Compatibility

Repave (`make repave`) deletes all Argo CD Applications and rebuilds from Git. Because service
Application CRs live in `manifests/apps/` in this repo, they are automatically re-created during
bootstrap and Argo re-reconciles all services without any manual intervention.

### Future Considerations

- If the number of services grows significantly (10+), consider introducing a dedicated Argo CD
  `AppProject` for services to restrict source repos, destination namespaces, and allowed resource
  kinds.
- If promotion between environments (dev → staging → prod) becomes a requirement, evaluate Argo CD
  ApplicationSets with a Git generator over environment branches or directories, or adopt a
  promotion tool such as Argo CD Image Updater with Git write-back.
- Option A remains viable if a dedicated platform team is hired and strict manifest ownership
  separation becomes a compliance requirement.
