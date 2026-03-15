#!/bin/bash
set -euo pipefail

# Only run in remote Claude Code on the web sessions
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Unshallow the clone so full git history (including tags) is available
if git rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
  echo "Unshallowing git clone to make full history and tags available..."
  git fetch --unshallow origin
else
  echo "Repository is not shallow, skipping unshallow."
fi
