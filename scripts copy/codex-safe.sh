#!/usr/bin/env bash
set -euo pipefail

exec codex \
  -c 'sandbox_mode="read-only"' \
  -c 'approval_policy="on-request"' \
  "$@"
