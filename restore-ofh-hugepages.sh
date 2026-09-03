#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

STATE_DIR="${HUGEPAGE_STATE_DIR:-/run/ocudu-ofh-hugepages}"
state_file="$STATE_DIR/state.before"
if [ ! -f "$state_file" ]; then
  echo "No saved OFH hugepage state in $STATE_DIR; nothing to restore."
  exit 0
fi

nr_hugepages="$(awk -F= '$1 == "nr_hugepages" {print $2}' "$state_file")"
was_mounted="$(awk -F= '$1 == "was_mounted" {print $2}' "$state_file")"
if [[ ! "$nr_hugepages" =~ ^[0-9]+$ ]] || [[ ! "$was_mounted" =~ ^[01]$ ]]; then
  echo "Saved hugepage state is invalid: $state_file" >&2
  exit 1
fi

failures=0
if [ "$was_mounted" -eq 0 ] && mountpoint -q /dev/hugepages; then
  if ! umount /dev/hugepages; then
    echo 'Warning: /dev/hugepages is busy; it was not unmounted.' >&2
    failures=$((failures + 1))
  fi
fi
if ! sysctl -q -w "vm.nr_hugepages=$nr_hugepages"; then
  echo "Warning: unable to restore vm.nr_hugepages=$nr_hugepages." >&2
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "Hugepage restore failed; saved state was retained in $STATE_DIR for retry." >&2
  exit 1
fi

rm -f -- "$state_file"
rmdir -- "$STATE_DIR" 2>/dev/null || true
echo "Restored vm.nr_hugepages=$nr_hugepages and the previous hugepage mount state."
