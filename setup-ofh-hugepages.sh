#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"

"$SCRIPT_DIR/validate-site-config.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

HUGEPAGES="${HUGEPAGES:-1024}"
STATE_DIR="${HUGEPAGE_STATE_DIR:-/run/ocudu-ofh-hugepages}"
install -d -m 0700 "$STATE_DIR"

if [ ! -f "$STATE_DIR/state.before" ]; then
  if mountpoint -q /dev/hugepages; then
    was_mounted=1
  else
    was_mounted=0
  fi
  {
    printf 'nr_hugepages=%s\n' "$(sysctl -n vm.nr_hugepages)"
    printf 'was_mounted=%s\n' "$was_mounted"
  } > "$STATE_DIR/state.before"
fi

restore_on_error() {
  local rc="${1:-$?}"
  trap - ERR INT TERM
  echo 'Hugepage setup failed; restoring saved hugepage state.' >&2
  HUGEPAGE_STATE_DIR="$STATE_DIR" "$SCRIPT_DIR/restore-ofh-hugepages.sh" || true
  exit "$rc"
}
trap 'restore_on_error $?' ERR
trap 'restore_on_error 130' INT
trap 'restore_on_error 143' TERM

sysctl -w "vm.nr_hugepages=$HUGEPAGES"
install -d -m 0755 /dev/hugepages
if ! mountpoint -q /dev/hugepages; then
  mount -t hugetlbfs -o pagesize=2M nodev /dev/hugepages
fi

allocated="$(awk '/HugePages_Total:/ {print $2}' /proc/meminfo)"
if [ "${allocated:-0}" -lt "$HUGEPAGES" ]; then
  echo "Only ${allocated:-0} of $HUGEPAGES requested 2-MiB hugepages were allocated." >&2
  exit 1
fi

echo "Allocated $allocated 2-MiB hugepages for the OFH deployment."
echo "Previous runtime state is saved in $STATE_DIR."
trap - ERR INT TERM
