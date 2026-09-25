#!/usr/bin/env bash
# Generation report for ticket.answer (design D5-9/D5-11). Talks to the Anthropic API
# directly — no Camunda, no database. Requires ANTHROPIC_API_KEY; uses the worker's venv
# if present.
#
#   tests/generation/report.sh              # one run over questions.json
#   tests/generation/report.sh --runs 2     # stability check
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${ANTHROPIC_API_KEY:-}" ] || [ "${ANTHROPIC_API_KEY:-}" = "REPLACE_ME" ]; then
  echo "error: ANTHROPIC_API_KEY is not set" >&2
  exit 1
fi

PYTHON=../../workers/llm-classifier/.venv/bin/python
[ -x "$PYTHON" ] || PYTHON=python3

exec "$PYTHON" report.py "$@"
