# ADR-004: Secret Management Strategy — Imperative Provisioning with Sealed Secrets Migration Path

| Field | Value |
|---|---|
| Status | Accepted |
| Date | 2026-04-30 |
| Deciders | Andrew Davies |
| Context | Pre-deployment — no secret management strategy existed |

## Context

The Sentic platform reached a point where services need external credentials to operate: API keys
for news providers (Alpha Vantage, Finnhub) and a Telegram bot token for the notifier. These
cannot be hard-coded, stored in `values.yaml`, or committed to Git in plaintext.

Three categories of secret exist in the cluster:

| Category | Example | Owner | Strategy |
|---|---|---|---|
| **Operator-generated** | `definition-default-user` (RabbitMQ credentials) | RabbitMQ Cluster Operator | Automatic — no action required |
| **External service credentials** | `sentic-signal-secrets` (API keys), `sentic-notifier-telegram` (bot token) | Platform operator | Must be provisioned before first Argo sync |
| **Platform infrastructure** | `repo-creds` (Argo CD GitHub PAT) | Bootstrap process | Handled by `make bootstrap` |

Operator-generated secrets are fully managed by the RabbitMQ Cluster Operator: the Secret is
created, rotated, and reconciled automatically. No manual action is needed.

The problem is exclusively with external service credentials. A decision was needed on how to
create, store, and rotate these secrets before the first cluster deployment.

## Decision Drivers

- Secrets must never be committed to Git in plaintext.
- The provisioning process must be repeatable and self-documenting.
- The solution must not add dependencies that block deployment — the cluster should be runnable
  today without installing additional operators.
- A clear migration path must exist for when the team grows or CI needs secret access.
- The solution should be consistent with the existing Makefile-driven operations model.

## Options Considered

### Option A — Provisioning Script Only

An idempotent shell script (`scripts/provision-secrets.sh`) and `make secrets` target create all
required platform secrets from environment variables. Secrets never live in Git. Operator supplies
values from a password manager or local `.env.secrets` file.

**Pros:**
- No new cluster dependencies.
- Self-documenting — the script is the runbook.
- Consistent with the existing `make bootstrap` pattern.
- Immediately unblocks deployment.

**Cons:**
- Secrets never in Git — no audit trail or GitOps history.
- CI pipelines cannot provision secrets without cluster access (not currently needed).

### Option B — Sealed Secrets (Bitnami)

Install the Sealed Secrets controller as a cluster operator. Encrypt secrets with the cluster's
public key using the `kubeseal` CLI. Commit the encrypted `SealedSecret` resources to Git.
The controller decrypts them into native Kubernetes Secrets.

**Pros:**
- Full GitOps purity — everything in Git, including secrets.
- Encrypted values are safe to commit.
- Native Argo CD support — SealedSecrets are synced like any other resource.

**Cons:**
- Requires installing an additional operator before first deployment.
- Cluster-specific encryption — if the cluster is repaved without backing up the encryption key,
  secrets must be re-sealed.
- Adds `kubeseal` as a local dev dependency.

### Option C — Provisioning Script Now, Sealed Secrets Later ✅ Chosen

Implement Option A to unblock deployment immediately. Document the migration path to Option B
explicitly. When the migration is carried out, the provisioning script becomes a `kubeseal`
wrapper — the interface (`make secrets`) does not change.

## Decision

**Option C is adopted.**

The provisioning script handles all external service secrets. The migration path to Sealed Secrets
is defined below and must be completed before the platform is operated by more than one person or
before CI pipelines need to provision secrets autonomously.

---

## Secret Inventory

All secrets are created in the `sentic` namespace.

### `sentic-signal-secrets`

Consumed by: `sentic-signal` (alpha_vantage and finnhub provider releases only).

| Key | Env var in pod | Required by |
|---|---|---|
| `alpha-vantage-key` | `ALPHA_VANTAGE_KEY` | `PROVIDER=alpha_vantage` |
| `finnhub-api-key` | `FINNHUB_API_KEY` | `PROVIDER=finnhub` |

Secret isolation is enforced in the Helm chart: each provider release only mounts its required
key. A pod running `PROVIDER=yahoo_rss` does not receive any keys from this secret.

### `sentic-notifier-telegram`

Consumed by: `sentic-notifier`.

| Key | Env var in pod | Notes |
|---|---|---|
| `bot-token` | `TELEGRAM_BOT_TOKEN` | BotFather token, e.g. `123456:ABC-...` |
| `chat-id` | `TELEGRAM_CHAT_ID` | Numeric channel or group ID |

### `definition-default-user` (operator-managed — no provisioning required)

Created automatically by the RabbitMQ Cluster Operator when the `RabbitmqCluster` resource is
applied. Contains `username`, `password`, `host`, and `port`. Referenced directly by service
Helm charts. Never manually created or modified.

---

## Provisioning

### Prerequisites

- `kubectl` configured for the target cluster (`make status` must succeed)
- `sentic` namespace must exist (created by `make bootstrap` or `kubectl create namespace sentic`)
- Credentials sourced from a password manager or local `.env.secrets` file (not committed to Git)

### Running

```bash
# Export credentials, then run the target:
export ALPHA_VANTAGE_KEY=<key>
export FINNHUB_API_KEY=<key>
export TELEGRAM_BOT_TOKEN=<token>
export TELEGRAM_CHAT_ID=<chat-id>

make secrets
```

The script is idempotent. Running it again updates existing secrets without error.

### What `make secrets` Creates

```
sentic namespace:
  sentic-signal-secrets
    alpha-vantage-key = $ALPHA_VANTAGE_KEY
    finnhub-api-key   = $FINNHUB_API_KEY
  sentic-notifier-telegram
    bot-token = $TELEGRAM_BOT_TOKEN
    chat-id   = $TELEGRAM_CHAT_ID
```

### Order of Operations (First Deployment)

Secrets must exist **before** Argo CD syncs service Applications. The CronJob pods for
`sentic-signal-alpha-vantage` and `sentic-signal-finnhub`, and the Deployment pod for
`sentic-notifier`, will fail to start if their referenced secrets do not exist.

```
1. make bootstrap          # Install Argo CD, operators
2. make secrets            # Create sentic-signal-secrets + sentic-notifier-telegram
3. git push sentic-infra   # Argo CD syncs Application CRs, services start
```

`sentic-signal-yahoo-rss` does not reference any keys from `sentic-signal-secrets` and can sync
and run successfully before `make secrets` is executed.

---

## Rotation

To rotate a credential, re-run `make secrets` with the new value exported. The script performs
an idempotent apply — the existing secret is updated in place.

Kubernetes does not automatically restart Deployments when a Secret changes. After rotation:

```bash
# Restart the notifier to pick up the new Telegram token:
kubectl rollout restart deployment/sentic-notifier -n sentic

# CronJobs read secrets at pod start — no manual restart needed.
# The next scheduled run will use the updated value.
```

---

## Migration Path to Sealed Secrets

When the team grows or CI pipelines need to provision secrets autonomously, migrate as follows:

1. Add the Sealed Secrets controller to `manifests/operators/sealed-secrets.yaml` and register
   it in `argocd/application.yaml` at an appropriate sync wave (e.g., wave 4).
2. Install `kubeseal` locally (`brew install kubeseal`).
3. Replace each `kubectl create secret ... | kubectl apply` block in `scripts/provision-secrets.sh`
   with a `kubeseal` call that encrypts the secret and writes a `SealedSecret` YAML file to
   `manifests/secrets/`. Commit those files to Git.
4. Remove the `make secrets` Makefile target (or convert it to a `make seal-secrets` helper that
   runs `kubeseal` over updated values).

The `make secrets` interface, secret names, and key structure do not change. Only the backend
implementation changes from imperative `kubectl` to declarative `SealedSecret` resources.

---

## Consequences

- Secrets are never committed to Git in plaintext.
- Operators must maintain their own secure credential storage (password manager).
- A cluster repave requires re-running `make secrets` before services become healthy.
- The migration to Sealed Secrets is explicit and documented — it is a deliberate future decision,
  not technical debt.
