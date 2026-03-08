#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

RELEASE="my-rag-app"
NAMESPACE="my-namespace"
TIMEOUT="10m"
PURGE_NAMESPACE="false"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Clean deployment resources only (no redeploy).

Options:
  --release <name>      Helm release name (default: $RELEASE)
  --namespace <ns>      Kubernetes namespace (default: $NAMESPACE)
  --timeout <duration>  Wait timeout for uninstall/delete (default: $TIMEOUT)
  --purge-namespace     Delete namespace after uninstall
  --help                Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --namespace my-namespace --release my-rag-app
  $SCRIPT_NAME --purge-namespace
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
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

uninstall_release() {
  if helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
    log "Uninstalling Helm release: $RELEASE (namespace: $NAMESPACE)"
    helm -n "$NAMESPACE" uninstall "$RELEASE" --wait --timeout "$TIMEOUT"
  else
    log "Release $RELEASE not found in namespace $NAMESPACE, skipping uninstall"
  fi
}

purge_namespace_if_requested() {
  if [[ "$PURGE_NAMESPACE" != "true" ]]; then
    return 0
  fi
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log "Deleting namespace: $NAMESPACE"
    kubectl delete namespace "$NAMESPACE" --wait=true --timeout="$TIMEOUT"
  else
    log "Namespace $NAMESPACE does not exist, nothing to delete"
  fi
}

main() {
  parse_args "$@"
  require_cmd helm
  require_cmd kubectl

  uninstall_release
  purge_namespace_if_requested
  log "Cleanup complete"
}

main "$@"
