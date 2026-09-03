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

compose() {
  docker compose --env-file "$OCUDU_CONFIG_FILE" "$@"
}

usage() {
  cat <<'EOF'
Usage: ./cudu.sh COMMAND

  init        Create config/site.env from the current-lab example
  setup       Install/prepare this host (run cudu.sh itself with sudo)
  render      Generate OCUDU YAML from config/site.env
  build       Build the pinned OCUDU image
  up          Start CU-CP and CU-UP only
  down        Stop all OCUDU containers
  status      Show containers
  logs        Follow CU logs
  check       Check configured IPs, NIC, CPU and generated files
  hugepages   Allocate configured runtime hugepages (root)
  pre-rf      Start active-cell DU with PA disabled; see README safety gates
EOF
}

case "$command_name" in
  setup) exec "$SCRIPT_DIR/setup.sh" "${@:2}" ;;
  render) exec "$SCRIPT_DIR/render-config.sh" ;;
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
  check) exec "$SCRIPT_DIR/check-environment.sh" ;;
  hugepages) exec "$SCRIPT_DIR/setup-ofh-hugepages.sh" ;;
  pre-rf)
    "$SCRIPT_DIR/render-config.sh"
    exec "$SCRIPT_DIR/start-ofh-pre-rf.sh"
    ;;
  -h|--help|help|'') usage ;;
  *) echo "Unknown command: $command_name" >&2; usage >&2; exit 2 ;;
esac
