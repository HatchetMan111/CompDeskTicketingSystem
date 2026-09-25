#!/usr/bin/env bash
#
# CompDesk Proxmox LXC one-liner installer (host side).
# Run on the Proxmox VE host as root:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CompDeskTicketingSystem/main/install/compdesk.sh)"
#
# Re-runnable: reuses the existing 'compdesk' container if present.
set -euo pipefail

# ---------------- variables (override via environment) ----------------
APP="${APP:-compdesk}"
BRANCH="${BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/HatchetMan111/CompDeskTicketingSystem.git}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/CompDeskTicketingSystem/main}"
HOSTNAME_CT="${HOSTNAME_CT:-compdesk}"
CTID="${CTID:-auto}"
VCPUS="${VCPUS:-2}"
RAM="${RAM:-2048}"
DISK="${DISK:-8}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
APP_PORT="${APP_PORT:-3000}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
ONBOOT="${ONBOOT:-1}"
DEBUG="${DEBUG:-0}"
# ----------------------------------------------------------------------

LOG="/tmp/${APP}-install-$(date +%Y%m%d-%H%M%S).log"

if [ "$DEBUG" = "1" ]; then
  set -x
fi

err() {
  local code=$?
  set +x
  echo "" >&2
  echo "================ COMPDSK INSTALL FAILED ================" >&2
  echo "Failed command : ${BASH_COMMAND}" >&2
  echo "Exit code      : ${code}" >&2
  echo "--- call stack (most recent first) ---" >&2
  local i=0
  while caller "$i" >&2; do
    i=$((i + 1))
  done
  echo "--- full log: ${LOG} ---" >&2
  echo "Re-run with debugging: DEBUG=1 bash -x install/compdesk.sh" >&2
  echo "Or: bash -x <(wget -qLO - ${RAW_BASE}/install/compdesk.sh)" >&2
  exit "$code"
}
trap err ERR

msg() { echo "==> $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this script as root on the Proxmox VE host." >&2
    exit 1
  fi
}

require_pve() {
  for bin in pct pveam pvesh; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "ERROR: '$bin' not found. Run this on a Proxmox VE host." >&2
      exit 2
    fi
  done
}

pick_ctid() {
  if [ "$CTID" = "auto" ]; then
    CTID="$(pvesh get /cluster/nextid)"
    msg "Using next free CT ID: ${CTID}"
  else
    msg "Using requested CT ID: ${CTID}"
  fi
}

existing_ct() {
  # NB: 'pct list' prints 3 cols when unlocked (VMID Status Name) but 4 when
  # locked (VMID Status Lock Name) -> always match the last field.
  pct list 2>/dev/null | awk -v h="$HOSTNAME_CT" '$NF == h {print $1; exit}'
}

resolve_template() {
  local tpl
  tpl="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-12-.*standard/ {print $1}' | sort -V | tail -n 1 || true)"
  if [ -z "$tpl" ]; then
    msg "No Debian 12 template cached, downloading (pveam update + download)..."
    pveam update
    local avail
    avail="$(pveam available --section system 2>/dev/null | awk '/debian-12-.*standard/ {print $2}' | sort -V | tail -n 1 || true)"
    if [ -z "$avail" ]; then
      echo "ERROR: no debian-12-standard template found via 'pveam available --section system'." >&2
      echo "--- pveam available output ---" >&2
      pveam available --section system >&2 || true
      exit 3
    fi
    pveam download "$TEMPLATE_STORAGE" "$avail"
    tpl="${TEMPLATE_STORAGE}:vztmpl/${avail}"
  fi
  echo "$tpl"
}

create_ct() {
  local tpl="$1"
  local rootpw
  rootpw="$(openssl rand -base64 32 | tr -d '/+=' | head -c 20)"
  msg "Creating container ${CTID} (${HOSTNAME_CT}) from ${tpl}..."
  pct create "$CTID" "$tpl" \
    --hostname "$HOSTNAME_CT" \
    --cores "$VCPUS" \
    --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" \
    --onboot "$ONBOOT" \
    --startup "order=2" \
    --password "$rootpw"
  echo "$rootpw" > "/tmp/${APP}-${CTID}.rootpw"
  chmod 600 "/tmp/${APP}-${CTID}.rootpw"
}

start_ct() {
  local state
  state="$(pct status "$CTID" | awk '{print $2}')"
  if [ "$state" != "running" ]; then
    msg "Starting container ${CTID}..."
    pct start "$CTID"
  else
    msg "Container ${CTID} already running."
  fi
  pct set "$CTID" --onboot "$ONBOOT" --startup "order=2"
}

wait_for_ip() {
  msg "Waiting for container network (up to 120s)..."
  local i ip
  for i in $(seq 1 24); do
    ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "${ip:-}" ]; then
      echo "$ip"
      return 0
    fi
    sleep 5
  done
  echo "ERROR: container ${CTID} got no IP within 120s." >&2
  echo "--- pct status ---" >&2
  pct status "$CTID" >&2
  echo "--- container journal (if any) ---" >&2
  pct exec "$CTID" -- journalctl -n 30 --no-pager >&2 || true
  exit 4
}

run_in_ct_setup() {
  msg "Running in-container setup (Node 24 + PostgreSQL 16 + CompDesk build)..."
  pct exec "$CTID" -- bash -c "set -euo pipefail; wget -qO /tmp/compdesk-install.sh '${RAW_BASE}/install/compdesk-install.sh' && bash /tmp/compdesk-install.sh"
}

verify() {
  msg "Verifying service inside container..."
  pct exec "$CTID" -- systemctl is-active --quiet compdesk
  msg "Service 'compdesk' is active."
  pct exec "$CTID" -- systemctl is-active --quiet postgresql
  msg "Service 'postgresql' is active."
  msg "Verifying Web UI (up to 150s, first start includes migrations)..."
  local i
  for i in $(seq 1 30); do
    if pct exec "$CTID" -- curl -fsS "http://127.0.0.1:${APP_PORT}/api/health/live" >/dev/null 2>&1; then
      msg "Web UI health check OK."
      return 0
    fi
    sleep 5
  done
  echo "ERROR: Web UI did not answer http://127.0.0.1:${APP_PORT}/api/health/live within 150s." >&2
  echo "--- systemctl status compdesk ---" >&2
  pct exec "$CTID" -- systemctl status compdesk --no-pager >&2 || true
  echo "--- journal (last 50) ---" >&2
  pct exec "$CTID" -- journalctl -u compdesk -n 50 --no-pager >&2 || true
  exit 5
}

print_summary() {
  local ip="$1"
  local rootpw=""
  if [ -f "/tmp/${APP}-${CTID}.rootpw" ]; then
    rootpw="$(cat "/tmp/${APP}-${CTID}.rootpw")"
  fi
  echo ""
  echo "================ COMPDESK READY ================"
  echo "Container : ${CTID} (${HOSTNAME_CT})"
  echo "IP        : ${ip}"
  echo "Web UI    : http://${ip}:${APP_PORT}"
  echo "Setup     : http://${ip}:${APP_PORT}/setup"
  echo "One-time setup token (valid 30 min):"
  echo "  pct exec ${CTID} -- journalctl -u compdesk -n 100 --no-pager | grep -i token"
  if [ -n "$rootpw" ]; then
    echo "CT root password (shown once, stored in /tmp/${APP}-${CTID}.rootpw): ${rootpw}"
  fi
  echo "Reboot test: pct stop ${CTID} && pct start ${CTID} -- then reopen the Web UI URL."
  echo "================================================="
}

main() {
  exec > >(tee -a "$LOG") 2>&1
  msg "CompDesk LXC installer (log: ${LOG})"
  require_root
  require_pve
  pick_ctid
  local existing
  existing="$(existing_ct || true)"
  if [ -n "${existing:-}" ] && [ "$existing" != "$CTID" ]; then
    msg "Found existing '${HOSTNAME_CT}' container: ${existing}. Reusing it (idempotent)."
    CTID="$existing"
  fi
  if pct status "$CTID" >/dev/null 2>&1; then
    msg "Container ${CTID} exists, skipping creation."
  else
    create_ct "$(resolve_template)"
  fi
  start_ct
  local ip
  ip="$(wait_for_ip)"
  msg "Container IP: ${ip}"
  run_in_ct_setup
  verify
  print_summary "$ip"
}

main "$@"
