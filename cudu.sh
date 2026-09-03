#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
command_name="${1:-}"

if [ "$command_name" = init ]; then
  if [ -e "$SCRIPT_DIR/config/site.env" ]; then
    echo 'config/site.env already exists; refusing to overwrite it.' >&2
    exit 1
  fi
  install -m 0644 "$SCRIPT_DIR/config/site.env.example" "$SCRIPT_DIR/config/site.env"
  echo 'Created config/site.env from the current-lab example.'
  echo 'Review every 5GC, O-RU, NIC, PTP, RF and CPU value before setup.'
  exit 0
fi

if [ "$command_name" = help ] || [ "$command_name" = --help ] ||
   [ "$command_name" = -h ] || [ -z "$command_name" ]; then
  show_help_only=1
else
  show_help_only=0
fi

if [ "$show_help_only" -eq 0 ]; then
# shellcheck source=load-site-env.sh
  source "$SCRIPT_DIR/load-site-env.sh"
fi

# Commands may be launched with sudo solely for Docker access. Keep generated
# files writable by the invoking user so later non-root rendering is repeatable.
restore_generated_ownership() {
  if [[ "${SUDO_UID:-}" =~ ^[0-9]+$ ]] &&
     [[ "${SUDO_GID:-}" =~ ^[0-9]+$ ]] &&
     [ "$SUDO_UID" -ne 0 ]; then
    for path in "$SCRIPT_DIR/config/generated" "$SCRIPT_DIR/logs"; do
      [ ! -e "$path" ] || chown -R -- "$SUDO_UID:$SUDO_GID" "$path"
    done
  fi
}
trap restore_generated_ownership EXIT

compose() {
  docker compose --env-file "$OCUDU_CONFIG_FILE" "$@"
}

usage() {
  cat <<'EOF'
Usage: ./cudu.sh COMMAND

  init        Create config/site.env from the current-lab example
  setup       Install/prepare this host (run cudu.sh itself with sudo)
  validate    Validate config/site.env without changing the host
  render      Generate OCUDU YAML from config/site.env
  build       Build the pinned OCUDU image
  up          Start CU-CP and CU-UP only
  down        Stop all OCUDU containers
  status      Show containers
  logs        Follow CU logs
  check       Check configured IPs, NIC, CPU and generated files
  hugepages   Allocate configured runtime hugepages (root)
  pre-rf      Start active-cell DU with PA disabled; see README safety gates
  stop-du     Stop only the OFH DU
  restore     Restore saved host OFH performance settings (root)
  restore-hugepages Restore saved hugepage count/mount state (root)
  cleanup-ofh Stop the DU, then restore host OFH performance settings (root)
EOF
}

case "$command_name" in
  setup) "$SCRIPT_DIR/setup.sh" "${@:2}" ;;
  validate) "$SCRIPT_DIR/validate-site-config.sh" ;;
  render) "$SCRIPT_DIR/render-config.sh" ;;
  build)
    "$SCRIPT_DIR/render-config.sh"
    docker build --build-arg "OCUDU_REF=$OCUDU_REF" -t "$OCUDU_IMAGE" .
    ;;
  up)
    "$SCRIPT_DIR/render-config.sh"
    compose up -d cu-cp cu-up
    compose ps
    ;;
  down) compose --profile ofh down ;;
  status) compose --profile ofh ps ;;
  logs) compose logs -f cu-cp cu-up ;;
  check) "$SCRIPT_DIR/check-environment.sh" ;;
  hugepages) "$SCRIPT_DIR/setup-ofh-hugepages.sh" ;;
  pre-rf)
    "$SCRIPT_DIR/render-config.sh"
    "$SCRIPT_DIR/start-ofh-pre-rf.sh"
    ;;
  stop-du) compose --profile ofh stop du ;;
  restore) "$SCRIPT_DIR/restore-ofh-performance.sh" ;;
  restore-hugepages) "$SCRIPT_DIR/restore-ofh-hugepages.sh" ;;
  cleanup-ofh)
    cleanup_status=0
    compose --profile ofh stop du || cleanup_status=$?
    "$SCRIPT_DIR/restore-ofh-performance.sh" || cleanup_status=$?
    "$SCRIPT_DIR/restore-ofh-hugepages.sh" || cleanup_status=$?
    exit "$cleanup_status"
    ;;
  -h|--help|help|'') usage ;;
  *) echo "Unknown command: $command_name" >&2; usage >&2; exit 2 ;;
esac
