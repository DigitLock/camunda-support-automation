#!/usr/bin/env bash
# Classifier calibration report (design D5-2). Talks to the Anthropic API directly —
# no Camunda, no database. Requires ANTHROPIC_API_KEY in the environment; uses the
# worker's venv if present.
#
#   tests/classification/report.sh              # one run, full 40-ticket set
#   tests/classification/report.sh --runs 3     # stability check
#   tests/classification/report.sh --subset e2e # only the 7 e2e tickets (5.2 step 7)
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${ANTHROPIC_API_KEY:-}" ] || [ "${ANTHROPIC_API_KEY:-}" = "REPLACE_ME" ]; then
  echo "error: ANTHROPIC_API_KEY is not set" >&2
  exit 1
fi

PYTHON=../../workers/llm-classifier/.venv/bin/python
[ -x "$PYTHON" ] || PYTHON=python3

exec "$PYTHON" report.py "$@"
