#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

RELEASE="my-rag-app"
NAMESPACE="my-namespace"
FLEX_DOCS_PATH=""
TIMEOUT="10m"
PURGE_NAMESPACE="false"
DEPLOY_ARGS=()

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options] --flex-docs-path <path> [-- <extra deploy.sh args>]

Clean current Helm deployment and redeploy using deploy.sh.

Options:
  --release <name>          Helm release name (default: $RELEASE)
  --namespace <ns>          Kubernetes namespace (default: $NAMESPACE)
  --flex-docs-path <path>   Absolute docs path on flex mount point (required)
  --timeout <duration>      Wait timeout for uninstall/delete operations (default: $TIMEOUT)
  --purge-namespace         Delete namespace and recreate before redeploy
  --help                    Show this help

Pass-through:
  Any args after '--' are forwarded to deploy.sh.
  Example:
    $SCRIPT_NAME --flex-docs-path /mnt/Flexcache_Site2 -- \\
      --gateway-host my-rag-app.45.63.79.40.nip.io \\
      --qdrant-url http://my-rag-app-qdrant:6333
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
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
      --flex-docs-path)
        [[ $# -ge 2 ]] || fail "--flex-docs-path requires a value"
        FLEX_DOCS_PATH="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || fail "--timeout requires a value"
        TIMEOUT="$2"
        shift 2
        ;;
      --purge-namespace)
        PURGE_NAMESPACE="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          DEPLOY_ARGS+=("$1")
          shift
        done
        break
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

cleanup_release() {
  if helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
    log "Uninstalling Helm release: $RELEASE (namespace: $NAMESPACE)"
    helm -n "$NAMESPACE" uninstall "$RELEASE" --wait --timeout "$TIMEOUT"
  else
    log "Release $RELEASE not found in namespace $NAMESPACE, skipping uninstall"
  fi
}

cleanup_namespace_if_requested() {
  if [[ "$PURGE_NAMESPACE" != "true" ]]; then
    return 0
  fi

  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log "Deleting namespace: $NAMESPACE"
    kubectl delete namespace "$NAMESPACE" --wait=true --timeout="$TIMEOUT"
  fi
  log "Recreating namespace: $NAMESPACE"
  kubectl create namespace "$NAMESPACE" >/dev/null
}

redeploy() {
  [[ -n "$FLEX_DOCS_PATH" ]] || fail "--flex-docs-path is required"
  [[ "$FLEX_DOCS_PATH" == /* ]] || fail "--flex-docs-path must be an absolute path"
  [[ -x ./deploy.sh ]] || fail "deploy.sh not found or not executable in current directory"

  local -a args
  args=(--release "$RELEASE" --namespace "$NAMESPACE" --flex-docs-path "$FLEX_DOCS_PATH")
  args+=("${DEPLOY_ARGS[@]}")

  log "Redeploying via ./deploy.sh"
  ./deploy.sh "${args[@]}"
}

main() {
  parse_args "$@"

  require_cmd helm
  require_cmd kubectl
  require_cmd bash

  cleanup_release
  cleanup_namespace_if_requested
  redeploy
}

main "$@"
