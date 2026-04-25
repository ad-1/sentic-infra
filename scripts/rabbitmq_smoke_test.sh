#!/usr/bin/env sh
set -eu

KUBE_CTX="${1:-minikube}"
NAMESPACE="${2:-sentic}"
CLUSTER="${3:-definition}"
QUEUE="${4:-raw-news}"

KUBECTL="kubectl --context=${KUBE_CTX} -n ${NAMESPACE}"
PF_PORT="15672"
PF_HOST="127.0.0.1"
BASE_URL="http://${PF_HOST}:${PF_PORT}"

echo "[smoke] context=${KUBE_CTX} namespace=${NAMESPACE} cluster=${CLUSTER} queue=${QUEUE}"

${KUBECTL} get rabbitmqcluster "${CLUSTER}" >/dev/null
${KUBECTL} get queue "${QUEUE}" >/dev/null

USER_NAME="$(${KUBECTL} get secret "${CLUSTER}-default-user" -o jsonpath='{.data.username}' | base64 --decode)"
PASSWORD="$(${KUBECTL} get secret "${CLUSTER}-default-user" -o jsonpath='{.data.password}' | base64 --decode)"

PAYLOAD="sentic-smoke-$(date +%s)"

echo "[smoke] starting temporary port-forward on ${PF_HOST}:${PF_PORT}"
kubectl --context="${KUBE_CTX}" -n "${NAMESPACE}" port-forward "svc/${CLUSTER}" "${PF_PORT}:15672" >/tmp/sentic-rmq-portforward.log 2>&1 &
PF_PID=$!

cleanup() {
  kill "${PF_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

READY=0
for _ in $(seq 1 20); do
  if curl -s -u "${USER_NAME}:${PASSWORD}" "${BASE_URL}/api/overview" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done

if [ "${READY}" -ne 1 ]; then
  echo "[smoke] management API did not become reachable on ${BASE_URL}" >&2
  exit 1
fi

PUBLISH_RESPONSE="$(
  curl -s -u "${USER_NAME}:${PASSWORD}" \
    -H 'content-type: application/json' \
    -X POST "${BASE_URL}/api/exchanges/%2F/amq.default/publish" \
    -d "{\"properties\":{},\"routing_key\":\"${QUEUE}\",\"payload\":\"${PAYLOAD}\",\"payload_encoding\":\"string\"}"
)"

echo "${PUBLISH_RESPONSE}" | grep -q '"routed":true' || {
  echo "[smoke] publish failed: ${PUBLISH_RESPONSE}" >&2
  exit 1
}

GET_RESPONSE="$(
  curl -s -u "${USER_NAME}:${PASSWORD}" \
    -H 'content-type: application/json' \
    -X POST "${BASE_URL}/api/queues/%2F/${QUEUE}/get" \
    -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto","truncate":50000}'
)"

echo "${GET_RESPONSE}" | grep -q "${PAYLOAD}" || {
  echo "[smoke] payload not found in queue ${QUEUE}. Response: ${GET_RESPONSE}" >&2
  exit 1
}

echo "[smoke] publish + consume check passed for queue ${QUEUE}"
