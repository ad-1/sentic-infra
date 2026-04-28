# Sentic Platform Roadmap

> Platform-level tracking for sentic-infra, sentic-signal, and sentic-notifier.
> Service-specific roadmaps (e.g. `sentic-signal/docs/ROADMAP.md`) track feature work within each service.
> Last updated: 2026-04-28

---

## Status Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Complete |
| 🔄 | In progress |
| ⬜ | Not started |
| ⚠️ | Blocked / has known issue |
| 💬 | Needs decision before work begins |

---

## Phase 1 — Source Control

> **Priority: Immediate.** Everything else depends on this.

| Task | Repo | Status | Notes |
|------|------|--------|-------|
| Init git + push to `ad-1/sentic-notifier` | sentic-notifier | ✅ | Repo initialized and pushed. `main` tracks `origin/main`. |
| Init git + push to `ad-1/sentic-signal` | sentic-signal | ✅ | Repo initialized and pushed. `main` now tracks `origin/main`. |
| Verify `ad-1/sentic-infra` is current | sentic-infra | ✅ | `HEAD -> main`, synced with origin |

---

## Phase 2 — Pre-Deployment Bug Fixes

> **Priority: Immediate.** These are blocking issues that will cause silent failures on deploy.

| Task | Repo | Status | Notes |
|------|------|--------|-------|
| Fix `deploy/chart/values.yaml`: `rabbitmq.queue` `analysis-results` → `notifications` | sentic-notifier | ✅ | Updated in chart values. |
| Upgrade Dockerfile from `python:3.9-slim-buster` to `python:3.11-slim` | sentic-notifier | ✅ | Runtime now aligned with `pyproject.toml` (`^3.11`). |
| Add non-root user to sentic-notifier Dockerfile | sentic-notifier | ✅ | Added dedicated `app` user and switched runtime user. |
| Migrate sentic-signal chart image from `andrewdavies/sentic-signal` (Docker Hub) to `ghcr.io/ad-1/sentic-signal` | sentic-signal | ✅ | Chart repository updated to GHCR namespace. |

---

## Phase 3 — CI/CD Pipelines

> Pattern defined in ADR-001: build image → push to `ghcr.io` → write image tag back to `values-dev.yaml` via PR. Registry decision: standardise on **ghcr.io** (free, no infra overhead, native GitHub Actions integration).

### sentic-notifier

| Task | Status | Notes |
|------|--------|-------|
| GitHub Actions: unit tests (`poetry run pytest tests/unit`) | ✅ | Runs on PR and push to `main`. Coverage reported via `pytest-cov`. |
| GitHub Actions: integration tests | ⬜ | `test_verify_chat.py` hits live Telegram — excluded from CI. Revisit after sentic-analyst defines the payload contract. |
| GitHub Actions: build Docker image | ✅ | `docker/build-push-action@v6` |
| GitHub Actions: push to `ghcr.io/ad-1/sentic-notifier` | ✅ | Tagged `sha-<short>` and `latest` via `docker/metadata-action` |
| GitHub Actions: write image tag back to `deploy/chart/values-dev.yaml` via PR | ✅ | `peter-evans/create-pull-request@v6` opens PR on every successful push to `main` |
| Trivy vulnerability scan | ✅ | Runs post-push; blocks `update-image-tag` job on `CRITICAL` findings |
| Coverage reporting | ✅ | `--cov=sentic_notifier --cov-report=term-missing` in test job |

### sentic-signal

| Task | Status | Notes |
|------|--------|-------|
| GitHub Actions: unit tests (`pytest tests/unit`) | ✅ | Runs on PR and push to `main`. Coverage reported via `pytest-cov`. |
| GitHub Actions: integration tests | ⬜ | `tests/integration/` is empty — populate once RabbitMQ publish/consume tests are written |
| GitHub Actions: build Docker image | ✅ | Multi-stage build, `docker/build-push-action@v6` |
| GitHub Actions: push to `ghcr.io/ad-1/sentic-signal` | ✅ | Tagged `sha-<short>` and `latest` |
| GitHub Actions: write image tag back to `deploy/sentic-signal-chart/values-dev.yaml` via PR | ✅ | `peter-evans/create-pull-request@v6` |
| Trivy vulnerability scan | ✅ | Blocks deployment on `CRITICAL` findings |
| Coverage reporting | ✅ | `--cov=sentic_signal --cov-report=term-missing` in test job |

---

## Phase 4 — Kubernetes Deployment (Helm + ArgoCD)

### sentic-notifier

| Task | Status | Notes |
|------|--------|-------|
| Verify Helm chart renders correctly (`helm template`) | ⬜ | After Phase 2 bug fixes |
| Provision `sentic-notifier-telegram` secret on minikube | ⬜ | Manual step; document in ONBOARDING.md |
| Confirm ArgoCD Application CR (`manifests/apps/sentic-notifier.yaml`) syncs after git setup | ⬜ | CR exists; blocked on Phase 1 |
| End-to-end smoke test: publish to `notifications` queue → Telegram message received | ⬜ | |

### sentic-signal

| Task | Status | Notes |
|------|--------|-------|
| Finalise Helm chart (`deploy/sentic-signal-chart/`) | sentic-signal | 🔄 | CronJob template in progress |
| Add ArgoCD Application CR: `manifests/apps/sentic-signal.yaml` | sentic-infra | ⬜ | Wave 20, same pattern as notifier CR |
| Provision `sentic-signal-secrets` on minikube | ⬜ | API keys for Alpha Vantage, Finnhub, etc. |
| Verify CronJob schedule and `concurrencyPolicy: Forbid` on minikube | ⬜ | |
| End-to-end smoke test: CronJob runs → news items appear in `raw-news` queue | ⬜ | |

---

## Phase 5 — Container Registry

> ✅ **Decided: `ghcr.io/ad-1/` is the standard registry for all services.**

- Free, no infra overhead, native GitHub Actions OIDC token auth
- sentic-notifier already aligned (`ghcr.io/ad-1/sentic-notifier`)
- sentic-signal chart migration from Docker Hub covered in Phase 2

---

## Phase 6 — sentic-analyst (Next Service)

> **Prioritised before deep notifier hardening.** Analyst owns the `analysis-results → notifications` message contract as the producer. Hardening notifier against an assumed `NotificationPayload` schema before analyst exists risks a refactor when the real contract is defined.

**Recommended sequencing:**
1. Fix notifier blockers (Phase 2) + git/CI (Phase 3) — quick wins, needed regardless
2. Build `sentic-analyst` — defines the output schema that notifier must consume
3. Harden notifier against the real, analyst-defined payload

| Service | Purpose | Status |
|---------|---------|-------|
| `sentic-analyst` | Consumes `raw-news`, runs LLM/heuristic analysis, publishes to `analysis-results` | ⬜ Not started — **next after Phase 3** |
| `sentic-quant` | Consumes `analysis-results` for quantitative modelling | ⬜ Not started |

New services should follow the onboarding guide in `docs/ONBOARDING.md`.

---

## Infrastructure Target

| Stage | Platform | Notes |
|-------|----------|-------|
| **Now** | Laptop minikube | Development and initial validation |
| **Long-term** | Lenovo ThinkCentre i5 (dedicated node) | Always-on, no laptop resource contention. Use **k3s** (production-grade, lightweight, no VM overhead vs minikube). GitOps transition is low-friction — repoint ArgoCD at the same GitHub repos. |

CI runners (GitHub Actions) will not have direct cluster access. The GitOps loop (CI writes image tag → ArgoCD pulls and syncs) means runners never need `kubectl` access to the cluster.

---

## Open Questions

> All questions from initial roadmap are resolved. New questions go here.

| # | Question | Owner |
|---|----------|-------|
| 1 | When to provision the ThinkCentre with k3s — before or after Phase 4 validation on laptop minikube? | Andrew |
