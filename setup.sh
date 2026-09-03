#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKIP_PACKAGES=0
SKIP_NETWORK=0
for arg in "$@"; do
  case "$arg" in
    --skip-packages) SKIP_PACKAGES=1 ;;
    --skip-network) SKIP_NETWORK=1 ;;
    -h|--help)
      echo 'Usage: sudo ./setup.sh [--skip-packages] [--skip-network]'
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo 'Run as root: sudo ./setup.sh' >&2
  exit 1
fi

# setup is normally launched through sudo. Return generated runtime artifacts
# to the invoking user so a later non-root `./cudu.sh render` remains
# idempotent. Never apply caller-provided ownership outside these fixed paths.
restore_generated_ownership() {
  if [[ "${SUDO_UID:-}" =~ ^[0-9]+$ ]] &&
     [[ "${SUDO_GID:-}" =~ ^[0-9]+$ ]] &&
     [ "$SUDO_UID" -ne 0 ]; then
    for path in "$SCRIPT_DIR/config/generated" "$SCRIPT_DIR/logs"; do
      if [ -e "$path" ]; then
        chown -R -- "$SUDO_UID:$SUDO_GID" "$path"
      fi
    done
  fi
}
trap restore_generated_ownership EXIT

# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"

if [ -z "${RU_MGMT_ADDR:-}" ]; then
  echo 'RU_MGMT_ADDR is required for the host O-RU management path.' >&2
  echo 'Set an unused fronthaul CIDR in config/site.env; it must differ from RU_IP and GM_IP.' >&2
  exit 1
fi
ru_mgmt_ip="${RU_MGMT_ADDR%/*}"
if [ "$ru_mgmt_ip" = "$RU_IP" ] || [ "$ru_mgmt_ip" = "$GM_IP" ]; then
  echo "RU_MGMT_ADDR conflicts with RU_IP or GM_IP: $RU_MGMT_ADDR" >&2
  exit 1
fi
if [ "$PTP_ROLE" != external-gm ]; then
  echo "Core setup requires PTP_ROLE=external-gm; optional diagnostics are isolated under optional/." >&2
  exit 1
fi

if [ "$SKIP_PACKAGES" -eq 0 ]; then
  if [ ! -r /etc/os-release ]; then
    echo 'This automatic installer supports apt-based Ubuntu/Debian hosts.' >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) echo "Unsupported automatic-install OS: ${ID:-unknown}" >&2; exit 1 ;;
  esac
  packages=(linuxptp ethtool iproute2 iputils-ping arping tcpdump gettext-base util-linux pciutils kmod)
  if ! command -v docker >/dev/null 2>&1; then
    packages+=(docker.io)
  fi
  if ! docker compose version >/dev/null 2>&1; then
    packages+=(docker-compose-v2)
  fi
  apt-get update
  apt-get install -y "${packages[@]}"
  systemctl enable --now docker
fi

for command_name in docker envsubst ip ethtool ptp4l phc2sys pmc; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  fi
done
docker compose version >/dev/null

if ! ip link show "$FH_IF" >/dev/null 2>&1; then
  echo "Configured fronthaul interface does not exist: $FH_IF" >&2
  echo 'Edit config/site.env for this machine, then rerun setup.' >&2
  exit 1
fi

if [ "$SKIP_NETWORK" -eq 0 ]; then
  ip link set "$FH_IF" up
  if ! ip -4 addr show dev "$FH_IF" | grep -Fq "$RU_MGMT_ADDR"; then
    if [ "$(cat "/sys/class/net/$FH_IF/carrier" 2>/dev/null || echo 0)" = 1 ]; then
      arp_probe="$(arping -0 -i "$FH_IF" -c 3 -w 3 "$ru_mgmt_ip" 2>&1 || true)"
      if printf '%s\n' "$arp_probe" | grep -Eq '[1-9][0-9]* packets received'; then
        echo "Address conflict detected for $ru_mgmt_ip on $FH_IF." >&2
        exit 1
      fi
      if ! printf '%s\n' "$arp_probe" | grep -Eq '[0-9]+ packets transmitted, 0 packets received'; then
        echo "Could not verify that $ru_mgmt_ip is unused:" >&2
        printf '%s\n' "$arp_probe" >&2
        exit 1
      fi
    else
      echo "Warning: $FH_IF has no carrier; cannot probe $ru_mgmt_ip for conflicts." >&2
      echo 'Adding the operator-confirmed address, but DU startup remains blocked until carrier is present.' >&2
    fi
    ip addr add "$RU_MGMT_ADDR" dev "$FH_IF"
  fi

  if [ -n "${N3_PARENT_INTERFACE:-}" ] &&
     ! ip link show "$N3_INTERFACE" >/dev/null 2>&1; then
    if ! ip link show "$N3_PARENT_INTERFACE" >/dev/null 2>&1; then
      echo "N3 parent interface does not exist: $N3_PARENT_INTERFACE" >&2
      exit 1
    fi
    ip link add link "$N3_PARENT_INTERFACE" name "$N3_INTERFACE" type vlan id "$N3_VLAN_ID"
  fi
  for plane in N2 N3; do
    interface_name="${plane}_INTERFACE"
    cidr_name="${plane}_LOCAL_CIDR"
    interface="${!interface_name:-}"
    cidr="${!cidr_name:-}"
    if [ -n "$interface" ]; then
      if ! ip link show "$interface" >/dev/null 2>&1; then
        echo "$plane interface does not exist: $interface" >&2
        exit 1
      fi
      ip link set "$interface" up
      if ! ip -4 addr show dev "$interface" | grep -Fq "${cidr%/*}/"; then
        ip addr add "$cidr" dev "$interface"
      fi
    else
      echo "$plane interface is blank; expecting ${cidr%/*} to be configured externally."
    fi
  done
fi

"$SCRIPT_DIR/render-config.sh"
HUGEPAGES="$HUGEPAGES" "$SCRIPT_DIR/setup-ofh-hugepages.sh"

echo
echo 'Setup completed without starting OCUDU or enabling RF.'
echo 'Next: ./cudu.sh build && ./cudu.sh up'
