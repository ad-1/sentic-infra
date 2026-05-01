#!/usr/bin/env bash
set -euo pipefail

msg_file="${1:-}"
if [[ -z "${msg_file}" || ! -f "${msg_file}" ]]; then
  echo "commit-msg validator: missing commit message file path."
  exit 1
fi

subject="$(sed -n '1p' "${msg_file}" | tr -d '\r')"
pattern='^([A-Z]{2,10}-[0-9]+|[A-Z]{2,4}-[0-9]{8}-[0-9]{4}): [a-z0-9].+'

if [[ -z "${subject}" ]]; then
  echo "Invalid commit message: subject is empty."
  exit 1
fi

if [[ "${#subject}" -gt 120 ]]; then
  echo "Invalid commit message: subject exceeds 120 characters."
  echo "Actual: ${subject}"
  exit 1
fi

if ! [[ "${subject}" =~ ${pattern} ]]; then
  echo "Invalid commit message: ${subject}"
  echo "Expected format: <WORK_ID>: <imperative-summary>"
  echo "Examples:"
  echo "  SIG-42: simplify docker install layer order"
  echo "  GH-317: add smoke check for rabbitmq publisher"
  echo "  INF-20260501-0840: document bootstrap prerequisites"
  exit 1
fi
