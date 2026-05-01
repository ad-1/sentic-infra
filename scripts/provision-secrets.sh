#!/usr/bin/env bash
# scripts/provision-secrets.sh
#
# Idempotent provisioning of all external service secrets for the Sentic platform.
#
# See docs/adr/ADR-004-SECRET-MANAGEMENT.md for the full strategy and migration path.
#
# Usage:
#   export ALPHA_VANTAGE_KEY=<key>
#   export FINNHUB_API_KEY=<key>
#   export TELEGRAM_BOT_TOKEN=<token>
#   export TELEGRAM_CHAT_ID=<chat-id>
#   ./scripts/provision-secrets.sh [--context <kube-context>] [--namespace <namespace>]
#
# All flags are optional. Defaults:
#   --context   minikube
#   --namespace sentic
#
# Secrets created:
#   sentic-signal-secrets     — alpha-vantage-key, finnhub-api-key
#   sentic-notifier-telegram  — bot-token, chat-id
#
# The operator-generated secret 'definition-default-user' is managed by the
# RabbitMQ Cluster Operator and must NOT be created or modified by this script.
#
# Idempotence: uses `kubectl create secret --dry-run=client -o yaml | kubectl apply -f -`
# so re-running with updated values safely updates existing secrets without error.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (overridable via flags)
# ---------------------------------------------------------------------------
KUBE_CTX="minikube"
NAMESPACE="sentic"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      KUBE_CTX="$2"; shift 2 ;;
    --namespace)
      NAMESPACE="$2"; shift 2 ;;
    *)
      echo "❌ Unknown argument: $1"
      echo "   Usage: $0 [--context <kube-context>] [--namespace <namespace>]"
      exit 1 ;;
  esac
done

KUBECTL="kubectl --context=${KUBE_CTX} -n ${NAMESPACE}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo "🔍 Preflight checks..."

command -v kubectl >/dev/null 2>&1 || {
  echo "❌ kubectl not found. Install it and ensure it is on your PATH."
  exit 1
}

# Verify the context exists
kubectl config get-contexts "${KUBE_CTX}" >/dev/null 2>&1 || {
  echo "❌ Kubernetes context '${KUBE_CTX}' not found."
  echo "   Available contexts:"
  kubectl config get-contexts --no-headers -o name | sed 's/^/   /'
  exit 1
}

# Verify the namespace exists
${KUBECTL} get namespace "${NAMESPACE}" >/dev/null 2>&1 2>/dev/null || \
  kubectl --context="${KUBE_CTX}" get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
  echo "❌ Namespace '${NAMESPACE}' does not exist in context '${KUBE_CTX}'."
  echo "   Run 'make bootstrap' or 'kubectl create namespace ${NAMESPACE}' first."
  exit 1
}

echo "✅ Preflight passed (context=${KUBE_CTX}, namespace=${NAMESPACE})."

# ---------------------------------------------------------------------------
# Helper: apply a secret idempotently
# Prints a warning and skips if any required literal value is empty.
# ---------------------------------------------------------------------------
apply_secret() {
  local name="$1"
  shift
  # "$@" is a list of "--from-literal=key=value" arguments

  # Validate: check none of the values are empty
  local missing=0
  for arg in "$@"; do
    # Extract "key=value" from "--from-literal=key=value"
    local kv="${arg#--from-literal=}"
    local key="${kv%%=*}"
    local value="${kv#*=}"
    if [[ -z "${value}" ]]; then
      echo "⚠️  WARNING: key '${key}' in secret '${name}' is empty — skipping secret creation."
      echo "   Export the missing environment variable and re-run 'make secrets'."
      missing=1
    fi
  done

  if [[ "${missing}" -eq 1 ]]; then
    return 0
  fi

  kubectl create secret generic "${name}" \
    --namespace="${NAMESPACE}" \
    --context="${KUBE_CTX}" \
    "$@" \
    --dry-run=client -o yaml \
  | kubectl apply --context="${KUBE_CTX}" -f -

  echo "✅ Secret '${name}' applied in namespace '${NAMESPACE}'."
}

# ---------------------------------------------------------------------------
# sentic-signal-secrets
# Keys: alpha-vantage-key, finnhub-api-key
# Consumed by sentic-signal CronJob pods (conditionally, per PROVIDER).
# ---------------------------------------------------------------------------
echo ""
echo "📦 Provisioning sentic-signal-secrets..."
apply_secret "sentic-signal-secrets" \
  "--from-literal=alpha-vantage-key=${ALPHA_VANTAGE_KEY:-}" \
  "--from-literal=finnhub-api-key=${FINNHUB_API_KEY:-}"

# ---------------------------------------------------------------------------
# sentic-notifier-telegram
# Keys: bot-token, chat-id
# Consumed by sentic-notifier Deployment pods.
# ---------------------------------------------------------------------------
echo ""
echo "📦 Provisioning sentic-notifier-telegram..."
apply_secret "sentic-notifier-telegram" \
  "--from-literal=bot-token=${TELEGRAM_BOT_TOKEN:-}" \
  "--from-literal=chat-id=${TELEGRAM_CHAT_ID:-}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "🎉 Secret provisioning complete."
echo ""
echo "   Secrets in namespace '${NAMESPACE}':"
kubectl --context="${KUBE_CTX}" -n "${NAMESPACE}" get secrets \
  sentic-signal-secrets sentic-notifier-telegram \
  --ignore-not-found \
  -o custom-columns="NAME:.metadata.name,KEYS:.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration" \
  2>/dev/null || true
kubectl --context="${KUBE_CTX}" -n "${NAMESPACE}" get secrets \
  sentic-signal-secrets sentic-notifier-telegram \
  --ignore-not-found \
  2>/dev/null || true
echo ""
echo "   Next: git push sentic-infra main → Argo CD will sync services."
echo "   Note: 'definition-default-user' is operator-managed — no action needed."
