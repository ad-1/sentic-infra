# ADR-003: Pipeline Architecture — Five-Stage Discovery-to-Analysis Chain

| Field | Value |
|---|---|
| Status | Accepted |
| Date | 2026-04-29 |
| Deciders | Andrew Davies |
| Context | Architectural review of pipeline stages between sentic-signal and sentic-analyst |

## Context

The original pipeline placed `sentic-analyst` as the direct consumer of `raw-news`, assigning it
responsibility for content enrichment (turning 3-sentence API summaries into analysis-worthy text),
deduplication, batch windowing, and multi-agent LLM reasoning. As the analyst design matured —
particularly the Multi-Agent War Room model and the need for rolling narrative memory via RAG — it
became clear these were distinct responsibilities conflated into one service.

A second gap was identified: Alpha Vantage, Finnhub, and Yahoo RSS return headlines and short
summaries, not full article text. Running a Bear/Bull/Synthesizer agent pattern over summaries
produces shallow output. The War Room model requires full article Markdown to surface genuine
investment arguments.

This ADR defines the correct service boundaries before any analyst code is written.

## Decision Drivers

- LLM agents need full article text, not 3-sentence summaries, to produce meaningful Bear/Bull
  analysis.
- Deduplication, batch windowing, and content enrichment are mechanical I/O concerns that must not
  live inside the reasoning layer.
- `sentic-analyst` should receive a clean, pre-processed batch and do nothing except reason over it.
- A rolling narrative memory (RAG) requires a stable indexing point: after enrichment, before
  analysis.
- `sentic-signal` is functionally complete. Its contract (`NewsItem` → `raw-news`) must not be
  modified.

## Options Considered

### Option A: Fat Analyst (original design)

`sentic-analyst` consumes `raw-news` directly, handles deduplication, fetches full text, batches
articles, and runs the War Room agents.

**Pros:** Fewer services to operate.

**Cons:** Violates single-responsibility. Makes analyst harder to test, scale, and reason about.
Enrichment failures pollute the reasoning layer. Batching logic and agent logic are tightly coupled.

### Option B: Five-Stage Pipeline ✅ Chosen

Insert two new services between `sentic-signal` and `sentic-analyst`:

1. **`sentic-extractor`** — consumes `NewsItem` from `raw-news`, calls Jina Reader to fetch full
   article Markdown from the URL, publishes an `EnrichedNewsItem` (with `full_text` field) to
   `rich-content`.

2. **`sentic-aggregator`** — consumes `rich-content`, deduplicates by URL hash, buffers items per
   ticker until a flush threshold is met, indexes each item into ChromaDB, publishes a
   `ContentBatch` to `enriched-batches`.

3. **`sentic-analyst`** — consumes `ContentBatch` from `enriched-batches`, queries ChromaDB for
   narrative context, dispatches to three agents, saves the Daily Chapter, publishes results.

**Pros:** Each service has a single testable responsibility. Enrichment failures are isolated. The
analyst receives pre-processed batches and does nothing except reason. The vector store is populated
at the aggregation boundary, giving the analyst RAG access to historical narrative.

**Cons:** Two additional services to scaffold, deploy, and monitor.

## Decision

**Option B is adopted.** The pipeline is restructured into five processing stages with four
RabbitMQ queue boundaries:

```
sentic-signal
  →[raw-news]→
sentic-extractor
  →[rich-content]→
sentic-aggregator
  →[enriched-batches]→
sentic-analyst
  →[analysis-results / notifications]→
sentic-notifier / sentic-quant
```

## Consequences

### New Queue Topology

| Queue | Publisher | Consumer | Purpose |
|---|---|---|---|
| `raw-news` | `sentic-signal` | `sentic-extractor` | Raw `NewsItem` objects (URL + summary) |
| `rich-content` | `sentic-extractor` | `sentic-aggregator` | `EnrichedNewsItem` with `full_text` |
| `enriched-batches` | `sentic-aggregator` | `sentic-analyst` | `ContentBatch` per ticker — deduplicated, windowed, indexed |
| `analysis-results` | `sentic-analyst` | `sentic-quant` | `AnalysisResult` with fused score and narrative |
| `notifications` | `sentic-analyst`, `sentic-quant` | `sentic-notifier` | `NotificationPayload` — outbound alert |

The two new queues (`rich-content`, `enriched-batches`) must be added to
`manifests/topology/queues.yaml` in `sentic-infra`.

### sentic-extractor Responsibilities

- Consume `NewsItem` from `raw-news`.
- Call **Jina Reader API** (`GET https://r.jina.ai/<url>`) to retrieve full article Markdown.
- Publish `EnrichedNewsItem` (`NewsItem` + `full_text: str | None`) to `rich-content`.
- On Jina failure (rate limit, paywall, timeout): set `full_text=None`, still publish. Never drop
  a message. The aggregator falls back to the `summary` field when `full_text` is absent.

**Reader API:** Jina Reader chosen for Stage 1 — generous free tier, clean LLM-ready Markdown, zero
scraping infrastructure. Firecrawl is the upgrade path for paywalled sources if Jina proves
insufficient.

**Target source priority:** Reuters, PR Newswire, BusinessWire, and Stat News are highest value.
Bloomberg and WSJ paywalls are expected to return `full_text=None` — this is acceptable.

### sentic-aggregator Responsibilities

- Consume `rich-content` items.
- Deduplicate by URL hash (SQLite for MVP; Redis for production).
- Buffer items per ticker in memory.
- Flush a batch when **either** threshold is met: **N ≥ 10 articles** OR **4 hours elapsed** since
  the first item arrived for that ticker (whichever comes first).
- Index each flushed item into **ChromaDB** for RAG access by `sentic-analyst`.
- Publish a `ContentBatch` (`list[EnrichedNewsItem]` + ticker + window metadata) to
  `enriched-batches`.

**Vector DB:** ChromaDB chosen for Stage 1 — runs locally, zero infrastructure overhead,
well-supported by LangChain, self-hostable on ThinkCentre alongside k3s. Weaviate is the migration
path if multi-node deployment is required.

### sentic-analyst Responsibilities

- Consume `ContentBatch` from `enriched-batches`.
- Query ChromaDB for recent narrative context (previous Daily Chapters for the ticker).
- Dispatch to three agents in sequence:
  - **Bear Agent (Red Team):** finds litigation risk, patent expiry, slowing growth, macro
    headwinds hidden in the batch.
  - **Bull Agent (Blue Team):** finds dividend stability, pipeline approvals, market share gains.
  - **Synthesizer (Narrator):** reads Bear critique and Bull defence, writes the "Daily Chapter" —
    a fused directional signal with magnitude (`Bullish / Neutral / Bearish` + score).
- Save the Daily Chapter to ChromaDB (rolling narrative memory — agents read their own previous
  chapters when analysing tomorrow's news).
- Publish `AnalysisResult` to `analysis-results`.
- Publish a formatted summary to `notifications` → Telegram.

**LLM hosting decision deferred.** Options: Ollama self-hosted on ThinkCentre (zero cost,
acceptable latency for batch processing) vs OpenAI/Anthropic API (better quality, cost per call).
A follow-up ADR is required before Phase 9 begins. No fine-tuning — RAG over ChromaDB provides
historical context without retraining.

### New Message Contracts

| Schema | Owner | Definition |
|---|---|---|
| `EnrichedNewsItem` | `sentic-extractor` | `NewsItem` + `full_text: str \| None` |
| `ContentBatch` | `sentic-aggregator` | `list[EnrichedNewsItem]` + ticker + window start/end + item count |
| `AnalysisResult` | `sentic-analyst` | Fused score, directional signal, Bear summary, Bull summary, Daily Chapter text |

`AnalysisResult` is deferred until `sentic-analyst` is scaffolded. Its definition will drive
notifier hardening and quant scoping.

### Deduplication Ownership

Deduplication moves from previously unowned (a gap) to `sentic-aggregator`. This is the correct
boundary: dedup should occur at the point where items are being collected into a batch, not at
ingestion time.
