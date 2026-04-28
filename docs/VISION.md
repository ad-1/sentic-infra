# Sentic — Project Vision

> **Status: Working Document** — This is a living document. Revise it as the vision becomes clearer
> and decisions are made.

## What Is Sentic?

Sentic is a financial analysis and signal engine built on an event-driven microservice architecture.
Its goal is to ingest news and market data for a given ticker (starting with **JNJ**), run it
through a pipeline of sentiment, LLM critique, and quantitative analysis, and surface actionable
signals — initially via Telegram notifications.

The system is designed to scale horizontally: once the pipeline is proven for a single ticker, the
same services can run in parallel for additional tickers without re-engineering.

---

## Pipeline Overview

```
                        ┌─────────────────────────────────────────────────────┐
  External sources      │                    RabbitMQ                         │
  ─────────────────     │  ┌─────────────┐  ┌──────────────┐  ┌────────────┐ │
  Yahoo Finance         │  │  raw-news   │  │analysis-res. │  │notificatns │ │
  Alpha Vantage    ───▶ │  │   queue     │  │    queue     │  │   queue    │ │
  Reddit                │  └──────┬──────┘  └──────┬───────┘  └─────┬──────┘ │
  (others TBD)          └─────────│─────────────────│────────────────│────────┘
                                  │                 │                │
                      ┌───────────▼──────┐ ┌────────▼──────────┐   │
                      │  sentic-signal   │ │  sentic-analyst   │   │
                      │  (ingester)      │ │  • Sentiment NLP  │   │
                      │  Standardise &   │ │  • LLM red/blue   │   │
                      │  publish items   │ │    team critique  │   │
                      └──────────────────┘ │  • Fused score    │   │
                                           └────────────────────┘   │
                                                                     │
                                                          ┌──────────▼──────────┐
                                                          │  sentic-notifier    │
                                                          │  Dispatches alerts  │
                                                          │  → Telegram         │
                                                          └─────────────────────┘

                            ┌──────────────────────────────────────┐
                            │           sentic-quant               │
                            │  Algorithmic / portfolio analysis    │
                            │  Backtesting · Min-max variance      │
                            │  (consumes analysis-results)         │
                            └──────────────────────────────────────┘

                            ┌──────────────────────────────────────┐
                            │         Telegram bot input           │
                            │  User sends ticker → triggers full   │
                            │  pipeline run on demand              │
                            └──────────────────────────────────────┘
```

---

## Services

### sentic-signal — News Ingester

Ingests raw news from external sources and publishes standardised article objects to the
`raw-news` queue.

**Design goal:** New data sources should be onboardable without touching existing code. Each source
is an adapter that maps its native response format to a shared `NewsItem` schema.

| | |
|---|---|
| Consumes | External APIs (Yahoo Finance, Alpha Vantage, Reddit, ...) |
| Publishes | `raw-news` queue |
| Language | TBD |
| Repo | `sentic-signal` (not yet created) |

**Open questions:**
- What is the canonical `NewsItem` schema? (headline, body, source, ticker, published_at, url, ...)
- Pull model (cron/polling) or push model (webhooks where available)?
- Rate limiting and deduplication strategy across sources.
- How frequently to ingest — continuous stream, hourly batch, or on-demand trigger?

---

### sentic-analyst — Sentiment & LLM Analysis

Consumes `raw-news`, runs each article through NLP sentiment analysis, then through a red
team / blue team LLM critique to counter-balance pure sentiment scores.

**Design goal:** Never trust a single model. The red/blue team pattern surfaces both the strongest
bull and bear arguments for a piece of news before arriving at a fused score.

| | |
|---|---|
| Consumes | `raw-news` queue |
| Publishes | `analysis-results`, `analytics-events`, `notifications` (summary alerts) |
| Language | TBD |
| Repo | `sentic-analyst` (not yet created) |

**Open questions:**
- Which NLP sentiment model? (FinBERT is a strong candidate for financial text.)
- Which LLM(s) for red/blue team? (Self-hosted via Ollama, or API calls to OpenAI/Anthropic?)
- Granularity of sentiment output: per-article score, daily aggregate, rolling weekly score?
- What metrics constitute the "fused score"? (e.g. weighted average of NLP + red score + blue score,
  clamped to a directional signal: bullish / neutral / bearish + magnitude.)
- Does each article get its own Telegram notification, or only aggregated summaries?

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
| `raw-news` | `sentic-signal` | `sentic-analyst` | Unprocessed news articles |
| `analysis-results` | `sentic-analyst` | `sentic-quant` | Scored / enriched articles |
| `notifications` | `sentic-analyst`, `sentic-quant` | `sentic-notifier` | Outbound alert payloads |
| `analytics-events` | `sentic-analyst` | TBD | Internal analytics / audit trail |

---

## Delivery Stages

The following phased breakdown keeps scope manageable and validates assumptions early.

### Stage 1 — Notification Pipeline (complete)
- [x] `sentic-notifier`: consume from `notifications` queue, send to Telegram
- [x] Define `notifications` message contract (`NotificationPayload` in `sentic-notifier/models.py`)
- [ ] Prove end-to-end: manually publish a test message → Telegram message received

### Stage 2 — News Ingestion
- [ ] Define canonical `NewsItem` schema
- [ ] `sentic-signal`: Yahoo Finance adapter → publishes to `raw-news`
- [ ] Add Alpha Vantage and Reddit adapters
- [ ] Establish deduplication and idempotency strategy

### Stage 3 — Sentiment Analysis
- [ ] `sentic-analyst`: consume `raw-news`, run FinBERT (or equivalent)
- [ ] Decide per-article vs. aggregated scoring cadence
- [ ] Publish raw articles to `notifications` (article alert → Telegram)

### Stage 4 — LLM Red/Blue Team
- [ ] Integrate LLM critique into `sentic-analyst`
- [ ] Define red/blue team prompt structure
- [ ] Produce fused directional score; publish to `analysis-results`
- [ ] Publish sentiment summary to `notifications` → Telegram

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

| Service | Leading candidate | Rationale |
|---|---|---|
| `sentic-signal` | Python or Go | Python has the richest API client ecosystem; Go for low-latency polling |
| `sentic-analyst` | Python | Best ML/NLP library support (FinBERT, Hugging Face, LangChain) |
| `sentic-notifier` | Python | Async I/O consumer (`aio-pika`); language decided. |
| `sentic-quant` | Python | NumPy, Pandas, SciPy, Backtrader, etc. |

Decisions do not need to be uniform. Document the choice and rationale in an ADR per service once
it is made.

---

## Open Questions & Decisions Needed

1. **Message contracts** — `NotificationPayload` (the `notifications` queue schema) is now defined
   and locked in `sentic-notifier`. `NewsItem` (the `raw-news` schema) is defined in
   `sentic-signal`. `AnalysisResult` still needs agreement before `sentic-analyst` is built.
2. **Sentiment granularity** — Per-article, daily aggregate, rolling weekly? This affects pipeline
   throughput design and downstream quant signal quality.
3. **LLM hosting** — Self-hosted (Ollama) vs. third-party API (OpenAI, Anthropic). Cost,
   latency, and data-privacy tradeoffs.
4. **Quant approach** — Backtest on sentiment signals, portfolio optimisation, or both? Needs a
   clear first target before `sentic-quant` is scoped.
5. **Notifier channel abstraction** — ~~Build for Telegram only now, or design an abstracted
   dispatcher from the start?~~ **Decided: Telegram-only for Stage 1.**
6. **Observability** — Metrics, tracing, and alerting strategy across services (Prometheus,
   OpenTelemetry). Out of scope for Stage 1 but worth noting.
