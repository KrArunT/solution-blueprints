#!/usr/bin/env bash
set -e

# ---- Help ----
if [[ "$1" =~ ^(--help|-h)$ ]]; then
  cat <<EOF
Usage:
  ./deploy.sh --flex-docs-path <path> [options]

Example:
  ./deploy.sh \\
    --flex-docs-path /mnt/<FlexcacheMountPoint> \\
    --gateway-host my-rag-app.<AIMS_PUBLIC_IP>.nip.io \\
    --qdrant-url http://<QDRANT_HOST>:6333

Options:
  --gateway-host       External hostname (HTTPRoute)
  --qdrant-url         External Qdrant endpoint
  --local-stage-dir    Local staging dir (default: \$HOME/docs)
  --model-cache-path   Model cache path
  --release            Helm release (default: my-rag-app)
  --namespace          Namespace (default: my-namespace)
  --llm-gpus           GPU count

EOF
  exit 0
fi

# ---- Defaults ----
RELEASE="my-rag-app"
NAMESPACE="my-namespace"
VALUES_FILE="values.yaml"
FLEX_TARGET="flex"
FLEX_DOCS_PATH=""
LOCAL_STAGE_DIR="$HOME/docs"
QDRANT_URL=""
MODEL_CACHE_PATH=""
LLM_GPUS=""
GATEWAY_HOST=""

# ---- Parse Args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --flex-docs-path) FLEX_DOCS_PATH="$2"; shift 2 ;;
    --qdrant-url) QDRANT_URL="$2"; shift 2 ;;
    --model-cache-path) MODEL_CACHE_PATH="$2"; shift 2 ;;
    --llm-gpus) LLM_GPUS="$2"; shift 2 ;;
    --gateway-host) GATEWAY_HOST="$2"; shift 2 ;;
    --local-stage-dir) LOCAL_STAGE_DIR="$2"; shift 2 ;;
    *) echo "❌ Unknown arg: $1 (use --help)"; exit 1 ;;
  esac
done

# ---- Required Arg ----
[[ -z "$FLEX_DOCS_PATH" ]] && { echo "❌ Missing --flex-docs-path (use --help)"; exit 1; }

APP_NAME="${RELEASE}-aimsb-talk-to-your-documents"

echo "🚀 Deploying: $RELEASE (ns: $NAMESPACE)"

# ---- Namespace ----
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ---- Helm Deploy ----
helm dependency update .
helm upgrade --install "$RELEASE" . -n "$NAMESPACE" -f "$VALUES_FILE" \
  ${QDRANT_URL:+--set qdrant.existingService=$QDRANT_URL} \
  ${MODEL_CACHE_PATH:+--set llm.localModelCache.enabled=true \
                       --set llm.localModelCache.hostPath=$MODEL_CACHE_PATH} \
  ${LLM_GPUS:+--set llm.gpus=$LLM_GPUS} \
  ${GATEWAY_HOST:+--set gatewayRoute.host=$GATEWAY_HOST}

# ---- Wait ----
kubectl -n "$NAMESPACE" rollout status deployment/$APP_NAME --timeout=20m

# ---- Access ----
if [[ -n "$GATEWAY_HOST" ]]; then
  BASE_URL="https://$GATEWAY_HOST"
  echo "🌐 Using Gateway: $BASE_URL"
else
  echo "🔌 Using port-forward..."
  kubectl -n "$NAMESPACE" port-forward svc/$APP_NAME 17860:80 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 5
  BASE_URL="http://127.0.0.1:17860"
fi

# ---- Sync Docs ----
STAGE_DIR="${LOCAL_STAGE_DIR}/${RELEASE}"
rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"

echo "📥 Syncing docs..."
rsync -az --include="*/" --include="*.pdf" --include="*.txt" --exclude="*" \
  "${FLEX_TARGET}:${FLEX_DOCS_PATH}/" "$STAGE_DIR/"

DOCS=($(find "$STAGE_DIR" -type f \( -iname "*.pdf" -o -iname "*.txt" \)))
[[ ${#DOCS[@]} -eq 0 ]] && { echo "❌ No docs found"; exit 1; }

echo "📄 Found ${#DOCS[@]} docs"

# ---- Get Pod ----
APP_POD=$(kubectl -n "$NAMESPACE" get pods -l app=$APP_NAME \
  -o jsonpath='{.items[0].metadata.name}')

# ---- Copy Docs ----
POD_DIR="/tmp/docs"
kubectl -n "$NAMESPACE" exec "$APP_POD" -- mkdir -p "$POD_DIR"

FILES_JSON=""
for f in "${DOCS[@]}"; do
  name=$(basename "$f")
  kubectl -n "$NAMESPACE" cp "$f" "$APP_POD:$POD_DIR/$name"
  FILES_JSON+="\"$POD_DIR/$name\","
done
FILES_JSON="[${FILES_JSON%,}]"

# ---- Index ----
echo "⚡ Indexing..."
curl -s -X POST "$BASE_URL/process" \
  -H "Content-Type: application/json" \
  -d "{\"question\":\"Summarize\",\"files\":$FILES_JSON}" >/dev/null

echo "✅ Deployment + Indexing Complete"

# ---- Cleanup ----
[[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
