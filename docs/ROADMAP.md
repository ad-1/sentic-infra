# Sentic Platform Roadmap

> Platform-level tracking for sentic-infra, sentic-signal, sentic-notifier, sentic-extractor, sentic-aggregator, and sentic-analyst.
> Service-specific roadmaps (e.g. `sentic-signal/docs/ROADMAP.md`) track feature work within each service.
> Last updated: 2026-04-29

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
| Upgrade Dockerfile from `python:3.9-slim-buster` to `python:3.13-slim` | sentic-notifier | ✅ | Runtime now aligned with `pyproject.toml` (`^3.13`). |
| Add non-root user to sentic-notifier Dockerfile | sentic-notifier | ✅ | Added dedicated `app` user and switched runtime user. |
| Migrate sentic-signal chart image from `andrewdavies/sentic-signal` (Docker Hub) to `ghcr.io/ad-1/sentic-signal` | sentic-signal | ✅ | Chart repository updated to GHCR namespace. |

---

## Phase 3 — CI/CD Pipelines

> Pattern defined in ADR-001: build image → push to `ghcr.io` → write image tag back to `values.yaml` via PR. Registry decision: standardise on **ghcr.io** (free, no infra overhead, native GitHub Actions integration).

### sentic-notifier

| Task | Status | Notes |
|------|--------|-------|
| GitHub Actions: unit tests (`poetry run pytest tests/unit`) | ✅ | Runs on PR and push to `main`. Coverage reported via `pytest-cov`. |
| GitHub Actions: integration tests | ⬜ | `test_verify_chat.py` hits live Telegram — excluded from CI. Revisit after sentic-analyst defines the payload contract. |
| GitHub Actions: build Docker image | ✅ | `docker/build-push-action@v6` |
| GitHub Actions: push to `ghcr.io/ad-1/sentic-notifier` | ✅ | Tagged `sha-<short>` and `latest` via `docker/metadata-action` |
| GitHub Actions: write image tag back to `deploy/chart/values.yaml` via PR | ✅ | `peter-evans/create-pull-request@v6` opens PR on every successful push to `main` |
| Trivy vulnerability scan | ✅ | Runs post-push; blocks `update-image-tag` job on `CRITICAL` findings |
| Coverage reporting | ✅ | `--cov=sentic_notifier --cov-report=term-missing` in test job |

### sentic-signal

| Task | Status | Notes |
|------|--------|-------|
| GitHub Actions: unit tests (`pytest tests/unit`) | ✅ | Runs on PR and push to `main`. Coverage reported via `pytest-cov`. Tests pass locally. |
| GitHub Actions: integration tests | ⬜ | `tests/integration/` is empty — populate once RabbitMQ publish/consume tests are written |
| GitHub Actions: build Docker image | ⚠️ | Workflow defined (`docker/build-push-action@v6`). **Not yet validated** — no successful CI run recorded in GHCR. |
| GitHub Actions: push to `ghcr.io/ad-1/sentic-signal` | ⚠️ | Workflow defined. **Not yet validated** — no image confirmed in GHCR. Requires repo workflow permissions set to Read and write. |
| GitHub Actions: write image tag back to `deploy/sentic-signal-chart/values.yaml` via PR | ⚠️ | Workflow defined (`peter-evans/create-pull-request@v6`). **Not yet validated** end-to-end. |
| Trivy vulnerability scan | ⚠️ | Defined in workflow. **Not yet validated** — depends on successful image push. |
| Coverage reporting | ✅ | `--cov=sentic_signal --cov-report=term-missing` confirmed working locally. |

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

## Phase 6 — Signal Hardening (Operational Gaps)

> **Complete before scaffolding new services.** `sentic-signal` is functionally complete but has
> unvalidated CI/CD and an incomplete Helm chart that block reliable deployment of downstream
> services.

### `NewsItem` contract — locked (ADR-003)

The `NewsItem` schema at the `signal→extractor` boundary is now locked:

| Field | Status | Notes |
|---|---|---|
| `ticker`, `headline`, `url`, `summary`, `published`, `relevance_score`, `source_provider` | ✅ Locked | Core discovery fields. Pass through all five stages. |
| `provider_sentiment` | ✅ Retained | Alpha Vantage raw label only. Always `None` for Yahoo RSS and Finnhub. Passes through unchanged. War room agents may reference it as one input. |
| `sentic_sentiment` | ✅ Removed | Field deleted from `NewsItem`. Sentiment scoring belongs in `sentic-analyst` (`AnalysisResult`). There is no producer for this field at the ingestor layer. |

**Key principle:** `sentic-signal` is a pure ingestor. It does not compute sentiment scores. The war room agents in `sentic-analyst` produce the definitive analysis after receiving full-text `ContentBatch` objects.

### Remaining hardening tasks

| Task | Repo | Status | Notes |
|------|------|--------|-------|
| Lock `NewsItem` schema: remove `sentic_sentiment`, clarify `provider_sentiment` scope | sentic-signal | ✅ | `sentic_sentiment` removed from model. `provider_sentiment` is AV-only raw label, retained. |
| Validate GitHub Actions: image build + push to `ghcr.io/ad-1/sentic-signal` | sentic-signal | ⚠️ | Workflow defined; no confirmed successful run. Requires repo workflow permissions = Read and write. |
| Validate image tag PR update (`values.yaml`) | sentic-signal | ⚠️ | `peter-evans/create-pull-request@v6` defined; not yet confirmed end-to-end. |
| Validate Trivy scan on published image | sentic-signal | ⚠️ | Depends on successful image push. |
| Add RabbitMQ subchart dependency to sentic-signal Helm chart | sentic-signal | ⚠️ | CronJob template in progress; subchart dependency missing. |
| Add ArgoCD Application CR: `manifests/apps/sentic-signal.yaml` | sentic-infra | ⬜ | Wave 20, same pattern as notifier CR. |
| Provision `sentic-signal-secrets` on minikube | sentic-infra | ⬜ | API keys: Alpha Vantage, Finnhub. |
| Add `rich-content` and `enriched-batches` queues to `manifests/topology/queues.yaml` | sentic-infra | ⬜ | Required by ADR-003 before extractor and aggregator can be deployed. |

---

## Phase 7 — sentic-extractor (New Service)

> **Next feature build after signal hardening.** Extraction is the missing stage between raw
> discovery and the analyst. Without full article text, the War Room agents have only 3-sentence
> summaries to reason over.
>
> **Responsibility:** Consume `NewsItem` from `raw-news` → call Jina Reader → publish
> `EnrichedNewsItem` (with `full_text`) to `rich-content`. Graceful fallback to `full_text=None`
> on paywall or timeout — never drops a message.

| Task | Status | Notes |
|------|--------|-------|
| Create GitHub repo `ad-1/sentic-extractor` | ⬜ | Follow `docs/ONBOARDING.md` |
| Define `EnrichedNewsItem` Pydantic schema | ⬜ | Extends `NewsItem` with `full_text: str \| None` |
| Implement Jina Reader API client | ⬜ | `GET https://r.jina.ai/<url>` → returns Markdown |
| RabbitMQ consumer (from `raw-news`) + publisher (to `rich-content`) | ⬜ | |
| Unit tests + CI pipeline | ⬜ | Same pattern as sentic-signal |
| Helm chart + ArgoCD CR | ⬜ | `manifests/apps/sentic-extractor.yaml` |

---

## Phase 8 — sentic-aggregator (New Service)

> **Depends on Phase 7.** Aggregator owns deduplication, batch windowing, and vector memory.
> These are mechanical concerns that must be resolved before the analyst's reasoning layer is
> introduced.
>
> **Responsibility:** Consume `rich-content` → dedup by URL hash → buffer per ticker → flush
> when N ≥ 10 OR 4h elapsed → index into ChromaDB → publish `ContentBatch` to `enriched-batches`.

| Task | Status | Notes |
|------|--------|-------|
| Create GitHub repo `ad-1/sentic-aggregator` | ⬜ | Follow `docs/ONBOARDING.md` |
| Define `ContentBatch` Pydantic schema | ⬜ | `list[EnrichedNewsItem]` + ticker + window metadata |
| Implement URL-hash deduplication (SQLite for MVP) | ⬜ | |
| Implement ticker-keyed batch window (count=10 OR time=4h) | ⬜ | |
| Integrate ChromaDB for vector indexing | ⬜ | Local self-hosted; see ADR-003 |
| RabbitMQ consumer + publisher | ⬜ | |
| Unit tests + CI pipeline | ⬜ | |
| Helm chart + ArgoCD CR | ⬜ | `manifests/apps/sentic-aggregator.yaml` |

---

## Phase 9 — sentic-analyst (Multi-Agent War Room)

> **Depends on Phase 8.** Analyst receives a clean, pre-processed `ContentBatch` and does nothing
> except reason over it. The `AnalysisResult` schema defined here unlocks notifier hardening
> and quant scoping.
>
> **Responsibility:** Consume `ContentBatch` from `enriched-batches` → query ChromaDB for
> narrative context → dispatch Bear / Bull / Synthesizer agents → save Daily Chapter to ChromaDB
> → publish `AnalysisResult` to `analysis-results` and summary to `notifications`.

| Task | Status | Notes |
|------|--------|-------|
| Create GitHub repo `ad-1/sentic-analyst` | ⬜ | Follow `docs/ONBOARDING.md` |
| Define `AnalysisResult` Pydantic schema | ⬜ | Fused score, directional signal, Bear summary, Bull summary, Daily Chapter text |
| LLM hosting decision (Ollama vs API) | 💬 | Deferred to a follow-up ADR — required before implementation begins |
| Implement Bear Agent (Red Team prompt) | ⬜ | |
| Implement Bull Agent (Blue Team prompt) | ⬜ | |
| Implement Synthesizer (Narrator prompt) | ⬜ | |
| ChromaDB RAG retrieval (narrative continuity) | ⬜ | Reads previous Daily Chapters for the ticker |
| Save Daily Chapter back to ChromaDB | ⬜ | Rolling narrative memory |
| Publish to `analysis-results` + `notifications` | ⬜ | |
| Unit tests + CI pipeline | ⬜ | |
| Helm chart + ArgoCD CR | ⬜ | `manifests/apps/sentic-analyst.yaml` |

| Service | Status |
|---------|--------|
| `sentic-quant` | ⬜ Not started — scoping deferred until `AnalysisResult` schema is defined in Phase 9 |

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

| # | Question | Owner |
|---|----------|-------|
| 1 | When to provision the ThinkCentre with k3s — before or after Phase 6 validation on laptop minikube? | Andrew |
| 2 | LLM hosting for sentic-analyst: Ollama (self-hosted on ThinkCentre) vs OpenAI/Anthropic API? Needs a follow-up ADR before Phase 9 begins. | Andrew |
| 3 | Jina Reader free tier throughput vs Firecrawl — evaluate once sentic-extractor is live and real-world volume is known. | Andrew |
| 4 | Should `sentic-extractor` and `sentic-aggregator` be combined into a single `sentic-enricher` service to reduce operational overhead? Currently kept separate for single-responsibility and independent scaling. | Andrew |
