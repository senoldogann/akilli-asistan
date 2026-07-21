#!/usr/bin/env bash
set -euo pipefail

exec codex \
  -c 'model_reasoning_effort="low"' \
  "$@"
