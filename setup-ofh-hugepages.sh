#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/load-site-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

HUGEPAGES="${HUGEPAGES:-1024}"

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

echo "Allocated $allocated 2-MiB hugepages for the RF-disabled OFH smoke test."
echo "This runtime allocation is cleared by reboot."
