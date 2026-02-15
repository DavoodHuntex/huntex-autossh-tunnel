#!/usr/bin/env bash
set -Eeuo pipefail

ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; }
die(){ log "[FATAL] $*"; exit 1; }

# ---------------- Inputs ----------------
IP="${IP:-}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"

UNIT="huntex-key-setup-${NAME}"

SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"
LOGFILE="/var/log/huntex-key-setup_${NAME}.log"

[[ -n "$IP" ]]   || die "IP is required"
[[ -n "$NAME" ]] || die "NAME is required"
[[ -n "$PASS" ]] || die "PASS is required"

# ---------------- Pipe-safe self-save ----------------
SELF="${SELF_PATH:-}"

if [[ -z "$SELF" ]]; then
  if [[ "${0##*/}" == "bash" || ! -f "$0" ]]; then
    SELF="/tmp/huntex-key-setup.$$.sh"
    cat >"$SELF"
    chmod +x "$SELF"
    export SELF_PATH="$SELF"
    exec "$SELF"
  else
    SELF="$0"
    export SELF_PATH="$SELF"
  fi
fi

# ---------------- Background via systemd ----------------
if [[ -z "${HUNTEX_BG:-}" ]]; then

  log "[*] Preparing systemd unit cleanup..."

  # ✅ FIX: Kill old transient unit if exists
  if systemctl list-units --all | grep -q "${UNIT}.service"; then
    log "[!] Old unit detected → cleaning..."

    systemctl stop "${UNIT}.service" 2>/dev/null || true
    systemctl reset-failed "${UNIT}.service" 2>/dev/null || true
  fi

  mkdir -p /var/log

  log "[*] Re-running in background. Logs → ${LOGFILE}"

  systemd-run --unit="${UNIT}" --collect --quiet \
    /usr/bin/env \
      HOME=/root \
      IP="$IP" PORT="$PORT" USER="$USER" NAME="$NAME" PASS="$PASS" WIPE_KEYS="$WIPE_KEYS" \
      HUNTEX_BG=1 SELF_PATH="$SELF" \
    /bin/bash -lc "'$SELF' >>'$LOGFILE' 2>&1" \
    || die "systemd-run failed"

  log "[+] Started"
  log "    tail -f ${LOGFILE}"
  exit 0
fi

# ================= REAL EXECUTION =================

log "==== HUNTEX KEY SETUP (${NAME}) ===="
log "[i] IP=${IP} PORT=${PORT}"
log "[i] KEY=${KEY}"

# Deps
if ! command -v sshpass >/dev/null 2>&1; then
  log "[*] Installing deps..."
  apt-get update -y
  apt-get install -y sshpass openssh-client
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ "$WIPE_KEYS" == "1" ]]; then
  log "[!] Removing old key artifacts for NAME only"
  rm -f "$KEY" "$PUB" "$KNOWN" || true
fi

log "[*] Resetting keypair"
rm -f "$KEY" "$PUB" || true

ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)"

chmod 600 "$KEY"
chmod 644 "$PUB"

PUB_LINE="$(cat "$PUB")"

log "[*] Installing key on remote"

sshpass -p "$PASS" ssh -p "$PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  "${USER}@${IP}" \
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
   touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
   grep -qxF '$PUB_LINE' ~/.ssh/authorized_keys || echo '$PUB_LINE' >> ~/.ssh/authorized_keys"

log "[*] Testing key login"

ssh -p "$PORT" -i "$KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  "${USER}@${IP}" "echo KEY_OK_FROM_${NAME}"

log "[+] DONE"
log "[+] KEY PATH → ${KEY}"
