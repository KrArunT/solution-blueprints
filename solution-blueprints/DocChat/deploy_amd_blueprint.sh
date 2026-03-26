#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

RELEASE="my-rag-app"
NAMESPACE="my-namespace"
QDRANT_URL=""
FLEX_TARGET="flex"
FLEX_DOCS_PATH=""
LOCAL_STAGE_DIR="$HOME/workspace/verify/solution-blueprints/solution-blueprints/DocChat/Docs"
VALUES_FILE="values.yaml"
MODEL_CACHE_PATH=""
SKIP_DEPENDENCY_UPDATE="false"
GATEWAY_HOST="${GATEWAY_HOST:-}"
LLM_GPUS=""

APP_NAME=""
APP_POD=""
PF_PID=""
PF_PORT=""
PF_LOG=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Deploy chart in current directory to local Kubernetes cluster, fetch docs from flex mount path,
and pre-index them into the app.

Options:
  --release <name>          Helm release name (default: $RELEASE)
  --namespace <ns>          Kubernetes namespace (default: $NAMESPACE)
  --qdrant-url <endpoint>   External Qdrant endpoint (default: $QDRANT_URL)
  --flex-target <target>    SSH target for doc source (default: $FLEX_TARGET)
  --flex-docs-path <path>   Absolute docs path on flex mount point (required)
  --local-stage-dir <path>  Local staging directory root (default: $LOCAL_STAGE_DIR)
  --values-file <file>      Helm values file to use (default: $VALUES_FILE)
  --model-cache-path <path> Absolute local model-cache path for LLM hostPath mount (optional)
  --gateway-host <host>     Gateway HTTPRoute hostname override (optional)
  --llm-gpus <count>        Override llm.gpus Helm value (positive integer, optional)
  --skip-dependency-update  Skip 'helm dependency update'
  --help                    Show this help

Examples:
  $SCRIPT_NAME --flex-docs-path /mnt/netapp/rag_docs
  $SCRIPT_NAME --namespace rag --release t2yd --flex-docs-path /netapp/docs --qdrant-url http://10.0.0.15:6333
  $SCRIPT_NAME --flex-docs-path /mnt/Flexcache_Site2 --model-cache-path /mnt/model-cache
  $SCRIPT_NAME --flex-docs-path /mnt/Flexcache_Site2 --llm-gpus 4
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" >/dev/null 2>&1; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

validate_positive_int() {
  local raw="$1"
  local arg_name="$2"
  [[ "$raw" =~ ^[1-9][0-9]*$ ]] || fail "$arg_name must be a positive integer"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release)
        [[ $# -ge 2 ]] || fail "--release requires a value"
        RELEASE="$2"
        shift 2
        ;;
      --namespace)
        [[ $# -ge 2 ]] || fail "--namespace requires a value"
        NAMESPACE="$2"
        shift 2
        ;;
      --qdrant-url)
        [[ $# -ge 2 ]] || fail "--qdrant-url requires a value"
        QDRANT_URL="$2"
        shift 2
        ;;
      --flex-target)
        [[ $# -ge 2 ]] || fail "--flex-target requires a value"
        FLEX_TARGET="$2"
        shift 2
        ;;
      --flex-docs-path)
        [[ $# -ge 2 ]] || fail "--flex-docs-path requires a value"
        FLEX_DOCS_PATH="$2"
        shift 2
        ;;
      --local-stage-dir)
        [[ $# -ge 2 ]] || fail "--local-stage-dir requires a value"
        LOCAL_STAGE_DIR="$2"
        shift 2
        ;;
      --values-file)
        [[ $# -ge 2 ]] || fail "--values-file requires a value"
        VALUES_FILE="$2"
        shift 2
        ;;
      --model-cache-path)
        [[ $# -ge 2 ]] || fail "--model-cache-path requires a value"
        MODEL_CACHE_PATH="$2"
        shift 2
        ;;
      --gateway-host)
        [[ $# -ge 2 ]] || fail "--gateway-host requires a value"
        GATEWAY_HOST="$2"
        shift 2
        ;;
      --llm-gpus)
        [[ $# -ge 2 ]] || fail "--llm-gpus requires a value"
        validate_positive_int "$2" "--llm-gpus"
        LLM_GPUS="$2"
        shift 2
        ;;
      --skip-dependency-update)
        SKIP_DEPENDENCY_UPDATE="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

read_hf_token_from_env() {
  local env_file=".env"
  local raw=""
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi

  raw="$(grep -E '^[[:space:]]*HF_TOKEN=' "$env_file" | tail -n 1 | cut -d'=' -f2- || true)"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  raw="${raw%\"}"
  raw="${raw#\"}"
  raw="${raw%\'}"
  raw="${raw#\'}"
  printf '%s' "$raw"
}

create_namespace() {
  log "Ensuring namespace exists: $NAMESPACE"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

create_hf_secret_if_present() {
  local hf_token
  hf_token="$(read_hf_token_from_env)"
  if [[ -z "$hf_token" ]]; then
    warn "HF_TOKEN not found in .env. Continuing without creating hf-token secret."
    return 0
  fi

  log "Creating/updating hf-token secret in namespace: $NAMESPACE"
  kubectl -n "$NAMESPACE" create secret generic hf-token \
    --from-literal=hf-token="$hf_token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

deploy_chart() {
  local -a helm_args
  [[ -f "$VALUES_FILE" ]] || fail "Values file not found: $VALUES_FILE"
  helm_args=(upgrade --install "$RELEASE" . -n "$NAMESPACE" -f "$VALUES_FILE")
  if [[ -n "$QDRANT_URL" ]]; then
    helm_args+=(--set "qdrant.existingService=$QDRANT_URL")
  fi
  if [[ -n "$MODEL_CACHE_PATH" ]]; then
    [[ "$MODEL_CACHE_PATH" == /* ]] || fail "--model-cache-path must be an absolute path"
    helm_args+=(
      --set "llm.localModelCache.enabled=true"
      --set-string "llm.localModelCache.hostPath=$MODEL_CACHE_PATH"
    )
  fi
  if [[ -n "$GATEWAY_HOST" ]]; then
    helm_args+=(--set "gatewayRoute.host=$GATEWAY_HOST")
  fi
  if [[ -n "$LLM_GPUS" ]]; then
    helm_args+=(--set "llm.gpus=$LLM_GPUS")
  fi

  if [[ "$SKIP_DEPENDENCY_UPDATE" != "true" ]]; then
    log "Updating helm dependencies"
    helm dependency update .
  else
    log "Skipping helm dependency update"
  fi

  log "Deploying Helm release: $RELEASE"
  helm "${helm_args[@]}"
}

wait_for_app() {
  APP_NAME="${RELEASE}-aimsb-talk-to-your-documents"
  log "Waiting for deployment rollout: $APP_NAME"
  kubectl -n "$NAMESPACE" rollout status "deployment/$APP_NAME" --timeout=20m
}

wait_for_llm_if_present() {
  local llm_deployment="llm-${RELEASE}"
  if kubectl -n "$NAMESPACE" get deployment "$llm_deployment" >/dev/null 2>&1; then
    log "Waiting for deployment rollout: $llm_deployment"
    kubectl -n "$NAMESPACE" rollout status "deployment/$llm_deployment" --timeout=90m
  else
    log "No in-cluster LLM deployment found for release; continuing"
  fi
}

start_port_forward_and_wait_health() {
  local port=""
  local -a candidate_ports=(17860 17861 17862 17863 17864)
  PF_LOG="$(mktemp)"

  for port in "${candidate_ports[@]}"; do
    kubectl -n "$NAMESPACE" port-forward "svc/$APP_NAME" "${port}:80" >"$PF_LOG" 2>&1 &
    PF_PID=$!
    sleep 2

    if ! kill -0 "$PF_PID" >/dev/null 2>&1; then
      wait "$PF_PID" 2>/dev/null || true
      PF_PID=""
      continue
    fi

    PF_PORT="$port"
    for _ in $(seq 1 90); do
      if curl -fsS "http://127.0.0.1:${PF_PORT}/health" >/dev/null 2>&1; then
        log "App health check succeeded on localhost:${PF_PORT}"
        return 0
      fi
      sleep 2
    done

    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=""
    PF_PORT=""
  done

  warn "Port-forward logs:"
  if [[ -f "$PF_LOG" ]]; then
    cat "$PF_LOG" >&2 || true
  fi
  fail "Failed to establish healthy port-forward to app service"
}

validate_flex_docs_path() {
  [[ -n "$FLEX_DOCS_PATH" ]] || fail "--flex-docs-path is required"
  [[ "$FLEX_DOCS_PATH" == /* ]] || fail "--flex-docs-path must be an absolute path"

  log "Checking docs path on ${FLEX_TARGET}: ${FLEX_DOCS_PATH}"
  local quoted_path
  quoted_path="$(printf '%q' "$FLEX_DOCS_PATH")"
  ssh "$FLEX_TARGET" "test -d $quoted_path" || fail "Path not found on ${FLEX_TARGET}: ${FLEX_DOCS_PATH}"
}

sync_docs_from_flex() {
  local stage_run
  stage_run="${LOCAL_STAGE_DIR%/}/${RELEASE}-${NAMESPACE}"
  mkdir -p "$stage_run"
  find "$stage_run" -mindepth 1 -delete

  log "Syncing .pdf/.txt documents from ${FLEX_TARGET}:${FLEX_DOCS_PATH} -> $stage_run"
  rsync -azs --prune-empty-dirs \
    --include='*/' \
    --include='*.pdf' \
    --include='*.txt' \
    --exclude='*' \
    "${FLEX_TARGET}:${FLEX_DOCS_PATH%/}/" \
    "$stage_run/"

  mapfile -d '' DOC_FILES < <(find "$stage_run" -type f \( -iname '*.pdf' -o -iname '*.txt' \) -print0 | sort -z)
  DOC_STAGE_RUN="$stage_run"
  DOC_COUNT="${#DOC_FILES[@]}"
  [[ "$DOC_COUNT" -gt 0 ]] || fail "No .pdf or .txt files found in ${FLEX_TARGET}:${FLEX_DOCS_PATH}"

  log "Fetched $DOC_COUNT document(s) from flex"
}

find_app_pod() {
  APP_POD="$(kubectl -n "$NAMESPACE" get pods \
    -l "app=$APP_NAME" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o name 2>/dev/null | tail -n 1 | cut -d'/' -f2 || true)"
  [[ -n "$APP_POD" ]] || fail "Could not find app pod with label app=$APP_NAME in namespace $NAMESPACE"
  log "Using app pod: $APP_POD"
}

copy_docs_to_pod_and_build_payload() {
  local pod_dir="/tmp/bootstrap_docs"
  local idx=0
  POD_DOC_PATHS=()
  local -A seen_names=()

  kubectl -n "$NAMESPACE" exec "$APP_POD" -- mkdir -p "$pod_dir"

  for src in "${DOC_FILES[@]}"; do
    idx=$((idx + 1))
    local dst_name
    local base_name
    base_name="$(basename "$src")"
    base_name="$(printf '%s' "$base_name" | sed -E 's/[^A-Za-z0-9._-]+/_/g')"
    [[ -n "$base_name" ]] || base_name="document_${idx}.txt"
    if [[ -n "${seen_names[$base_name]:-}" ]]; then
      dst_name="$(printf '%04d_%s' "$idx" "$base_name")"
    else
      dst_name="$base_name"
    fi
    seen_names["$dst_name"]=1
    local dst_path="${pod_dir}/${dst_name}"

    kubectl -n "$NAMESPACE" cp "$src" "${APP_POD}:${dst_path}"
    POD_DOC_PATHS+=("$dst_path")
  done

  # Validate copied paths inside the current app pod before triggering /process.
  local path=""
  for path in "${POD_DOC_PATHS[@]}"; do
    kubectl -n "$NAMESPACE" exec "$APP_POD" -- test -f "$path" || fail "Copied file not found in pod: $path"
  done

  local files_json=""
  local p=""
  for p in "${POD_DOC_PATHS[@]}"; do
    if [[ -n "$files_json" ]]; then
      files_json+=","
    fi
    files_json+="\"$p\""
  done

  INDEX_PAYLOAD="{\"question\":\"Summarize the uploaded documents.\",\"files\":[${files_json}]}"
}

index_documents() {
  log "Triggering indexing via /process"

  local response_file
  response_file="$(mktemp)"
  local http_code=""

  http_code="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X POST "http://127.0.0.1:${PF_PORT}/process" \
    -H 'Content-Type: application/json' \
    --data "$INDEX_PAYLOAD")"

  if [[ "$http_code" != "200" ]]; then
    warn "Response body:"
    cat "$response_file" >&2 || true
    fail "Indexing failed with HTTP status $http_code"
  fi

  if ! grep -q '"result"' "$response_file"; then
    warn "Response body:"
    cat "$response_file" >&2 || true
    fail "Indexing response missing 'result' field"
  fi

  if grep -q '"result"[[:space:]]*:[[:space:]]*""' "$response_file"; then
    warn "Response body:"
    cat "$response_file" >&2 || true
    fail "Indexing response has empty result"
  fi

  log "Indexing succeeded"
}

print_summary() {
  local qdrant_mode="bundled"
  if [[ -n "$QDRANT_URL" ]]; then
    qdrant_mode="external ($QDRANT_URL)"
  fi

  cat <<EOF

Deployment completed.
  Release:           $RELEASE
  Namespace:         $NAMESPACE
  Values File:       $VALUES_FILE
  App Service:       $APP_NAME
  Qdrant:            $qdrant_mode
  LLM GPUs:          ${LLM_GPUS:-from values.yaml}
  Model Cache Path:  ${MODEL_CACHE_PATH:-disabled}
  Gateway Host:      ${GATEWAY_HOST:-from values.yaml}
  Flex Docs Source:  ${FLEX_TARGET}:${FLEX_DOCS_PATH}
  Local Stage Dir:   $DOC_STAGE_RUN
  Indexed Files:     $DOC_COUNT
EOF
}

main() {
  parse_args "$@"

  require_cmd kubectl
  require_cmd helm
  require_cmd ssh
  require_cmd rsync
  require_cmd curl

  validate_flex_docs_path
  create_namespace
  create_hf_secret_if_present
  deploy_chart
  wait_for_app
  wait_for_llm_if_present
  start_port_forward_and_wait_health
  sync_docs_from_flex
  find_app_pod
  copy_docs_to_pod_and_build_payload
  index_documents
  print_summary
}

main "$@"
