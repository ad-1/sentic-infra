# Sentic — Project Vision

> **Status: Working Document** — This is a living document. Revise it as the vision becomes clearer
> and decisions are made.

## What Is Sentic?

Sentic is a **Digital Analyst Firm** built on an event-driven microservice architecture. Rather than
producing a single sentiment score, Sentic simulates an investment committee: a Multi-Agent War Room
of Bear, Bull, and Synthesizer agents debates every news batch and writes a "Daily Chapter" — a
living narrative for each ticker that accumulates into long-term memory via RAG.

Its goal is to ingest news from multiple providers, extract full article content, aggregate it into
meaningful batches, and subject each batch to rigorous multi-agent analysis before surfacing
actionable signals — initially via Telegram notifications.

The system is designed to scale horizontally: once the pipeline is proven for a single ticker, the
same services can run in parallel for additional tickers without re-engineering.

---

## Pipeline Overview

The pipeline processes news through five dedicated stages, each separated by a durable RabbitMQ
queue. Failures in any stage are isolated — the rest of the pipeline continues running.

```
  ┌──────────────────────────────────────────────────────┐
  │  External Sources                                    │
  │  Alpha Vantage · Yahoo Finance RSS · Finnhub         │
  └──────────────────────┬───────────────────────────────┘
                         │  Discovery APIs (URLs + summaries)
               ┌─────────▼──────────┐
               │   sentic-signal    │  Stage 1 — Discovery
               │  Fetch · Normalise │  BaseIngestor plug-ins per provider.
               └─────────┬──────────┘  Publishes standardised NewsItem objects.
                         │
                    [raw-news]
                         │
               ┌─────────▼──────────┐
               │  sentic-extractor  │  Stage 2 — Extraction
               │  URL → Jina Reader │  Full article Markdown via Jina Reader API.
               └─────────┬──────────┘  Graceful fallback on paywall / timeout.
                         │
                  [rich-content]
                         │
               ┌─────────▼──────────┐
               │ sentic-aggregator  │  Stage 3 — Aggregation & Memory
               │  Dedup · Window    │  Buffers per ticker (N=10 OR 4 h elapsed).
               │  ChromaDB index    │  Indexes into rolling vector narrative store.
               └─────────┬──────────┘
                         │
               [enriched-batches]
                         │
               ┌─────────▼──────────┐
               │  sentic-analyst    │  Stage 4 — Multi-Agent War Room
               │  Bear  ·  Bull     │  Red Team finds risk. Blue Team finds moat.
               │  Synthesizer       │  Narrator writes the "Daily Chapter."
               └────┬──────────┬────┘  RAG from ChromaDB for narrative continuity.
                    │          │
       [analysis-results]  [notifications]
                    │          │
        ┌───────────▼─┐   ┌────▼─────────────────┐
        │ sentic-quant │   │   sentic-notifier    │  Stage 5 — Notification
        │ Portfolio &  │   │  Dispatches alerts   │  Telegram (Stage 1).
        │ quant signals│   │  → Telegram          │
        └──────────────┘   └──────────────────────┘

               ┌──────────────────────────────────────┐
               │         Telegram bot input           │
               │  User sends ticker → triggers full   │
               │  pipeline run on demand              │
               └──────────────────────────────────────┘
```

---

## Services

### sentic-signal — News Ingester ✅ Complete

Fetches news from external providers and publishes standardised `NewsItem` objects to the `raw-news`
queue. Each provider is a `BaseIngestor` plug-in; new sources are onboardable without touching
existing code.

**Tiered Ingestion Strategy:**

| Tier | Sources | Role |
|---|---|---|
| **1 — Funnels** | Alpha Vantage · Yahoo Finance RSS · Finnhub | Discovery: map breaking news to tickers automatically. Return URL + summary only. Best for broad coverage. |
| **2 — Direct Feeds** | Stat News RSS · SEC EDGAR | High-value niche sources polled directly. Guarantees 100% coverage of pharmaceutical deep-dives (Stat News) and official filings (8-K, 10-Q). Produces full text without extraction. |
| **3 — Enrichment** | Jina Reader (sentic-extractor) | For Tier 1 URLs where only a summary was returned, the extractor fetches full article Markdown. Tier 2 items may skip extraction where full text is already available. |

This model avoids monitoring thousands of sites directly, uses AV/Yahoo as scouts, and reserves
direct feeds for sources where coverage guarantees and filing timeliness are non-negotiable.

| | |
|---|---|
| Consumes | Alpha Vantage · Yahoo Finance RSS · Finnhub · Stat News RSS · SEC EDGAR |
| Publishes | `raw-news` queue |
| Language | Python 3.13 |
| Repo | `ad-1/sentic-signal` |

**Decisions made:**
- `NewsItem` schema defined and locked (headline, url, summary, source_provider, ticker,
  published_at, provider_sentiment, sentic_sentiment).
- Provider-agnostic `BaseIngestor` protocol — runtime-checkable; all three Tier 1 providers conform.
- Tier 2 direct feeds (Stat News, SEC EDGAR) onboard as `BaseIngestor` plug-ins in Phase 6.
- Pull model (cron-based polling) for Stage 1. Webhook push deferred.
- RabbitMQ is the only dispatch target; no direct channel calls from this service.


---

### sentic-extractor — Content Extraction

Consumes raw `NewsItem` objects from `raw-news`, retrieves full article text via Jina Reader API,
and publishes enriched items to `rich-content`. This is the **Extraction** layer — it converts
discovery URLs into LLM-ready Markdown so the reasoning layer never deals with HTTP calls.

| | |
|---|---|
| Consumes | `raw-news` queue |
| Publishes | `rich-content` queue |
| Language | Python |
| Repo | `ad-1/sentic-extractor` (not yet created) |

**Key decisions (ADR-003):**
- **Jina Reader** (`GET https://r.jina.ai/<url>`) returns clean Markdown. Chosen for Stage 1 —
  generous free tier, no scraping infrastructure. Firecrawl is the upgrade path.
- On paywall or timeout: publish with `full_text=None`. Never drop a message. Downstream falls back
  to the `summary` field.
- Priority sources: Reuters, PR Newswire, BusinessWire, Stat News. Bloomberg/WSJ paywalls are
  expected to return `full_text=None` — this is acceptable.

---

### sentic-aggregator — Batch Aggregation & Vector Memory

Buffers enriched articles per ticker, deduplicates by URL hash, and flushes batches once a
threshold is met. Also owns the vector store — every article and Daily Chapter is indexed into
ChromaDB, giving `sentic-analyst` RAG access to the ticker's narrative history.

| | |
|---|---|
| Consumes | `rich-content` queue |
| Publishes | `enriched-batches` queue |
| Language | Python |
| Repo | `ad-1/sentic-aggregator` (not yet created) |

**Key decisions (ADR-003):**
- Flush trigger: **N ≥ 10 articles** OR **4 hours elapsed** since first item for the ticker
  (whichever comes first). Noise reduction: ten articles showing a trend is a Narrative Shift.
- Deduplication: URL hash (SQLite for MVP; Redis for production).
- **ChromaDB** chosen for vector store — self-hosted locally, zero infrastructure overhead,
  LangChain-compatible. Weaviate is the migration path if multi-node is needed.

---

### sentic-analyst — Multi-Agent War Room

Runs the investment committee debate for each batch. Three agents reason over the same
`ContentBatch` from different angles, producing a fused directional signal and a written "Daily
Chapter" that becomes the ticker's rolling narrative memory.

**Design goal:** Contextual Truth over simple sentiment. The red/blue team pattern surfaces the
strongest bear and bull arguments before a fused score is produced. RAG from ChromaDB gives agents
memory of yesterday's narrative.

| | |
|---|---|
| Consumes | `enriched-batches` queue |
| Publishes | `analysis-results` (for sentic-quant), `notifications` (for sentic-notifier) |
| Language | Python |
| Repo | `ad-1/sentic-analyst` (not yet created) |

**Agents:**
- **Bear Agent (Red Team):** finds litigation risk, patent expiry, slowing growth, macro headwinds.
- **Bull Agent (Blue Team):** finds dividend stability, pipeline approvals, market share gains.
- **Synthesizer (Narrator):** reads Bear critique and Bull defence, writes the Daily Chapter,
  assigns fused directional signal (Bullish / Neutral / Bearish + magnitude).

**Key decisions (ADR-003):**
- No fine-tuning. RAG over ChromaDB provides historical context — agents "read yesterday's chapter"
  before analysing today's news.
- Daily Chapter saved back to ChromaDB after each run (rolling narrative memory).
- LLM hosting (Ollama vs API) deferred to a follow-up ADR.

---

### sentic-notifier — Notification Dispatcher

Consumes messages from the `notifications` queue and dispatches them to configured channels.
The initial (and currently only) target is Telegram.

**Stage 1 implementation complete.** The service is registered in the cluster as an Argo CD
Application (`manifests/apps/sentic-notifier.yaml`).

| | |
|---|---|
| Consumes | `notifications` queue |
| Publishes | Telegram Bot API |
| Language | Python 3.11 |
| Repo | `sentic-notifier` |
| Message contract | `NotificationPayload` (see `sentic-notifier/sentic_notifier/models.py`) |

**Decisions made:**
- Telegram-only for Stage 1. Abstract dispatcher deferred until a second channel is needed.
- `notifications` queue contract locked as `NotificationPayload` — see `sentic-notifier` README.
- Dead-letter / retry handled at RabbitMQ topology level, not in service code.
- `aio-pika` chosen for async consumer loop (`pika` remains in `sentic-signal` for the publisher).

---

### sentic-quant — Quantitative Engine

Applies algorithmic and statistical analysis to the fused sentiment signals and optionally to raw
price data.

| | |
|---|---|
| Consumes | `analysis-results` queue, market price feeds (TBD) |
| Publishes | `notifications` queue (quant summary alerts), TBD |
| Language | Python (NumPy, Pandas, SciPy, or a quant library like Zipline / Backtrader) |
| Repo | `sentic-quant` (not yet created) |

**Open questions:**
- Do we train a model on our own sentiment signals and backtest it against historical price data?
- Do we feed JNJ into a portfolio context (mean-variance optimisation, max Sharpe, min variance)?
- How do we source historical and live price data? (yfinance, Alpha Vantage, a broker API?)
- What is the output format — a report, a signal, a trade recommendation?

---

## Queue Topology (Current)

Managed by the RabbitMQ Messaging Topology Operator in `manifests/topology/queues.yaml`.

| Queue | Publisher | Consumer | Purpose |
|---|---|---|---|
| `raw-news` | `sentic-signal` | `sentic-extractor` | Raw `NewsItem` objects (URL + summary) |
| `rich-content` | `sentic-extractor` | `sentic-aggregator` | `EnrichedNewsItem` with `full_text` |
| `enriched-batches` | `sentic-aggregator` | `sentic-analyst` | `ContentBatch` — deduplicated, windowed, indexed |
| `analysis-results` | `sentic-analyst` | `sentic-quant` | `AnalysisResult` with fused score and Daily Chapter |
| `notifications` | `sentic-analyst`, `sentic-quant` | `sentic-notifier` | `NotificationPayload` — outbound alert |
| `analytics-events` | `sentic-analyst` | TBD | Internal analytics / audit trail |

---

## Delivery Stages

The following phased breakdown keeps scope manageable and validates assumptions early.

### Stage 1 — Notification Pipeline (complete)
- [x] `sentic-notifier`: consume from `notifications` queue, send to Telegram
- [x] Define `notifications` message contract (`NotificationPayload` in `sentic-notifier/models.py`)
- [ ] Prove end-to-end: manually publish a test message → Telegram message received

### Stage 2 — News Ingestion ✅ Complete
- [x] Define canonical `NewsItem` schema
- [x] `sentic-signal`: Alpha Vantage, Yahoo Finance RSS, Finnhub adapters → `raw-news`
- [x] `BaseIngestor` protocol — new providers onboardable without touching existing code
- [ ] Validate CI/CD end-to-end (image build, GHCR push, tag-update PR)

### Stage 3 — Content Extraction
- [ ] `sentic-extractor`: consume `raw-news` → call Jina Reader → publish to `rich-content`
- [ ] Define `EnrichedNewsItem` schema (`NewsItem` + `full_text: str | None`)
- [ ] Graceful fallback: `full_text=None` on paywall/timeout; never drop a message

### Stage 4 — Aggregation & Vector Memory
- [ ] `sentic-aggregator`: consume `rich-content` → dedup → batch window → ChromaDB index
- [ ] Define `ContentBatch` schema and flush thresholds (N=10 OR 4h)
- [ ] ChromaDB set up locally; index enriched articles per ticker
- [ ] Publish `ContentBatch` to `enriched-batches`

### Stage 5 — Multi-Agent War Room
- [ ] `sentic-analyst`: consume `enriched-batches`, query ChromaDB for narrative context
- [ ] Implement Bear Agent (Red Team), Bull Agent (Blue Team), Synthesizer (Narrator)
- [ ] Define `AnalysisResult` schema (fused score, directional signal, Daily Chapter)
- [ ] Save Daily Chapter to ChromaDB (rolling narrative memory)
- [ ] Publish to `analysis-results` + `notifications` → Telegram

### Stage 5 — Quant Engine
- [ ] `sentic-quant`: consume `analysis-results`
- [ ] Implement backtesting against sentiment signals
- [ ] Implement portfolio optimisation (min variance / max Sharpe)
- [ ] Publish quant summary to `notifications` → Telegram

### Stage 6 — On-Demand Trigger
- [ ] Telegram bot input: user sends ticker → pipeline triggered
- [ ] Full pipeline run returns consolidated summary to requesting user

### Stage 7 — Horizontal Scale
- [ ] Parameterise all services on ticker symbol
- [ ] Run pipeline concurrently for additional tickers

---

## Technology Choices — Notes

There is no mandatory language constraint across services. Each service should use what best fits
its problem domain:

| Service | Language | Notes |
|---|---|---|
| `sentic-signal` | Python 3.13 ✅ decided | Richest API client ecosystem; `BaseIngestor` pattern proven. |
| `sentic-extractor` | Python | Lightweight HTTP client + Jina Reader; simple I/O worker. |
| `sentic-aggregator` | Python | ChromaDB + LangChain integration; SQLite dedup. |
| `sentic-analyst` | Python | Best ML/NLP library support (LangChain, Hugging Face, Ollama client). |
| `sentic-notifier` | Python 3.11 ✅ decided | Async I/O consumer (`aio-pika`). |
| `sentic-quant` | Python | NumPy, Pandas, SciPy, Backtrader, etc. |

Decisions do not need to be uniform. Document the choice and rationale in an ADR per service once
it is made.

---

## Open Questions & Decisions Needed

1. **Message contracts** — `NotificationPayload` ✅ locked. `NewsItem` ✅ locked. `EnrichedNewsItem`
   and `ContentBatch` to be defined in Phases 7–8. `AnalysisResult` deferred to Phase 9.
2. **Aggregation window strategy** — ~~Per-article vs. aggregated?~~ **Decided: batch window
   (N=10 OR 4h, whichever first).** This balances noise reduction with notification latency.
3. **LLM hosting** — Self-hosted Ollama (ThinkCentre) vs. OpenAI/Anthropic API. Cost, latency,
   and data-privacy tradeoffs. **Deferred to a follow-up ADR before Phase 9.**
4. **Reader API throughput** — Jina Reader free tier vs. Firecrawl. Evaluate once
   `sentic-extractor` is live and real-world throughput is known.
5. **Notifier channel abstraction** — ~~Build for Telegram only now, or design an abstracted
   dispatcher from the start?~~ **Decided: Telegram-only for Stage 1.**
6. **Quant approach** — Backtest on sentiment signals, portfolio optimisation, or both? Deferred
   until `AnalysisResult` schema is defined in Phase 9.
7. **Observability** — Metrics, tracing, and alerting strategy across services (Prometheus,
   OpenTelemetry). Out of scope for Stage 1 but worth noting.
