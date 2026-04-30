# ADR-002: Introduce `sentic-dx` as the Shared Developer Experience Repository

| Field | Value |
|---|---|
| Status | Accepted |
| Date | 2026-04-29 |
| Deciders | Andrew Davies |
| Context | Platform growth beyond three services exposes a missing canonical home for cross-cutting developer tooling |

## Context

As the Sentic platform grew from `sentic-infra` alone to a multi-service platform
(`sentic-notifier`, `sentic-signal`, and the forthcoming `sentic-analyst`), a category of
artefacts emerged that does not belong cleanly to any single service repo, nor to `sentic-infra`
(which is correctly scoped to cluster infrastructure):

- VS Code agent prompts that span all services (e.g. `ci-push-and-sync`)
- Custom agent definitions shared across service repos (`sentic-architect`, `sentic-reviewer`)
- Cross-service runbooks and onboarding guides
- Shared CI scripts and developer workflow tooling

Initially these were placed in `sentic-infra` as the closest available shared home. With
`sentic-analyst` now planned, the platform reaches four application services, the point at which
propagating this pattern to each new repo becomes unsustainable and the semantic mismatch
with `sentic-infra`'s infrastructure mandate becomes a liability.

## Decision Drivers

- `sentic-infra` should remain cluster-scoped. Mixing developer-experience tooling into it
  blurs its mandate and complicates onboarding for future contributors.
- Shared agent prompts and custom agents are currently duplicated or misplaced — a single
  canonical repo eliminates duplication.
- Every new service (`sentic-analyst`, and any future service) will share the same CI deploy
  cycle. A shared prompt updated in one place should propagate automatically.
- The VS Code multi-root workspace is the natural integration point: adding `sentic-dx` as a
  workspace folder makes its prompts and agents available in all repos simultaneously.

## Options Considered

### Option A: Continue using `sentic-infra` as the shared tooling home

Keep the current arrangement, accepting the semantic mismatch and growing the `.github/`
tooling directory inside `sentic-infra`.

**Pros:** No new repo to maintain; immediate.

**Cons:** Conflates cluster infrastructure with developer workflow tooling. Becomes increasingly
difficult to scope correctly as the service count grows. Misleads future contributors about
`sentic-infra`'s purpose.

### Option B: User-level VS Code prompts

Move shared prompts to `~/Library/Application Support/Code/User/prompts/`. These roam via
settings sync and are available in all workspaces.

**Pros:** Correct semantic scope (personal developer tooling); no repo overhead.

**Cons:** Not committed to version control, so not team-shareable or auditable. Breaks down
the moment a second developer joins the platform.

### Option C: Create `sentic-dx` — dedicated shared developer experience repo ✅ Chosen

A new, minimal repository that owns all cross-cutting developer tooling: VS Code prompts,
custom agent definitions, shared runbooks, and CI helper scripts.

**Pros:**
- Clean semantic boundary: infra owns the cluster, dx owns the developer workflow.
- Version-controlled and team-shareable from day one.
- Single update point for prompts and agents that apply to all services.
- Integrates naturally into the multi-root workspace — all prompts and agents are immediately
  discoverable across every service repo.
- Scales linearly with service count at no additional structural cost.

**Cons:**
- One additional repo to maintain.
- Slight onboarding overhead: new contributors must clone `sentic-dx` alongside the service repo.

## Decision

**Option C is adopted.**

A new repository `sentic-dx` is created in the `ad-1` GitHub organisation. It is added as a
folder in the `sentic-platform.code-workspace` multi-root workspace. All shared VS Code prompts
and custom agent definitions are migrated from `sentic-infra` into `sentic-dx`.

`sentic-infra` retains sole responsibility for cluster infrastructure manifests and ArgoCD
Application CRs. It holds no developer-experience tooling beyond this ADR.

## Consequences

### Immediate

- `sentic-dx` repository is created with the following structure:

```
sentic-dx/
  README.md
  .github/
    prompts/
      ci-push-and-sync.prompt.md   # migrated from sentic-infra
    agents/
      sentic-architect.agent.md    # migrated from sentic-signal
      sentic-reviewer.agent.md     # migrated from sentic-signal
```

- `sentic-platform.code-workspace` is updated to include `sentic-dx` as a workspace folder.
- The misplaced `.github/prompts/` directory is removed from `sentic-infra`.
- Shared agent definitions are removed from `sentic-signal` (they are not service-specific).

### Ongoing

- Each new Sentic service (`sentic-analyst`, etc.) registers its service-specific agents
  (e.g. `analyst-expert.agent.md`) in its own `.github/agents/` directory.
- Cross-service agents and prompts are added to `sentic-dx`.
- `sentic-dx` is listed as a required clone in `sentic-infra/docs/ONBOARDING.md`.
