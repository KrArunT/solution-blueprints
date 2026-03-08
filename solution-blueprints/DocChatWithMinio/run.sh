#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/deploy.sh" \
  --flex-docs-path /mnt/Flexcache_Site2 \
  --gateway-host my-rag-app.45.63.79.40.nip.io \
  --qdrant-url http://45.63.92.22:6333/ \
  --local-stage-dir "${HOME}/workspace/verify/solution-blueprints/solution-blueprints/DocChat/Docs" \
  --model-cache-path "${HOME}/workspace/Arun/model-cache"
