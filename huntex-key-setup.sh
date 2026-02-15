#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
# HUNTEX Key Setup (HPN SSH)
# - Generates a unique SSH key per IR server NAME
# - Pushes pubkey to remote HPN SSH server (port 2222)
# - Survives SSH disconnect via systemd-run
# - Fixes HOME issues inside systemd-run (ssh-copy-id mktemp bug)
# - Has a safe fallback (manual authorized_keys append) if ssh-copy-id fails
# ==============================

ts() { date '+%F %T'; }
log() { echo "[$(ts)] $*"; }
die() { log "[FATAL] $*"; exit 1; }

# ---- Inputs (env overrides) ----
IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"

# Always force correct HOME (critical for ssh-copy-id under systemd-run)
export HOME="/root"

SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"
LOG_FILE="/var/log/huntex-key-setup_${NAME}.log"

# Figure out the real script path (works when executed from file)
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

# ---- Run in background via systemd-run (survives SSH drop) ----
if [[ -z "${HUNTEX_BG:-}" ]]; then
  mkdir -p /var/log
  log "[*] Re-running in background via systemd-run. Logs: ${LOG_FILE}"

  # If script was piped (no real file), write a temp copy and run that
  if [[ -z "${SELF_PATH}" || ! -f "${SELF_PATH}" ]]; then
    TMP_SELF="/root/.cache/huntex-key-setup_${NAME}.sh"
    mkdir -p /root/.cache
    # Try to reconstruct from stdin if available
    if [[ ! -t 0 ]]; then
      cat >"$TMP_SELF"
      chmod +x "$TMP_SELF"
      SELF_PATH="$TMP_SELF"
    else
      die "Cannot determine script path. Please run from a file: curl -o /root/huntex-key-setup.sh ..."
    fi
  fi

  systemd-run --unit="huntex-key-setup-${NAME}" --collect --quiet \
    /usr/bin/env \
      HOME="/root" \
      IP="$IP" PORT="$PORT" USER="$USER" NAME="$NAME" PASS="$PASS" WIPE_KEYS="$WIPE_KEYS" \
      HUNTEX_BG="1" \
      bash -lc "\"$SELF_PATH\" >>\"$LOG_FILE\" 2>&1"

  log "[+] Started. Follow logs:"
  log "    tail -f ${LOG_FILE}"
  exit 0
fi

log "==== HUNTEX KEY SETUP (${NAME}) ===="
log "[i] IP=${IP} PORT=${PORT} USER=${USER}"
log "[i] KEY=${KEY}"
log "[i] HOME=${HOME}"

[[ -n "$PASS" ]] || die "PASS is empty. Provide PASS env var (no prompt mode)."

# ---- Install required tools ----
if ! command -v sshpass >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1; then
  log "[*] Installing deps (sshpass, openssh-client)..."
  apt-get update -y
  apt-get install -y sshpass openssh-client
fi

# ---- Ensure SSH dir ----
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---- Optional: wipe old key artifacts for THIS NAME only ----
if [[ "$WIPE_KEYS" == "1" ]]; then
  log "[!] WIPE_KEYS=1 -> Removing key artifacts for this NAME only"
  rm -f "$KEY" "$PUB" "$KNOWN" || true
  rm -f "${SSH_DIR}/ssh-copy-id."* 2>/dev/null || true
fi

# ---- Generate fresh key (always regenerate for this NAME) ----
log "[*] Generating fresh key for NAME=${NAME}"
rm -f "$KEY" "$PUB" || true
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null

chmod 600 "$KEY"
chmod 644 "$PUB"

[[ -s "$KEY" ]] || die "Key generation failed (missing: $KEY)"
[[ -s "$PUB" ]] || die "Key generation failed (missing: $PUB)"

# ---- SSH common options ----
SSH_OPTS=(
  -p "$PORT"
  -o "StrictHostKeyChecking=accept-new"
  -o "UserKnownHostsFile=$KNOWN"
  -o "ConnectTimeout=10"
  -o "ConnectionAttempts=3"
)

# ---- Try ssh-copy-id first (with correct HOME) ----
log "[*] Sending key to remote (ssh-copy-id)..."
set +e
HOME="/root" sshpass -p "$PASS" ssh-copy-id \
  -p "$PORT" \
  -i "$PUB" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  "${USER}@${IP}"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  log "[!] ssh-copy-id failed (rc=$RC) -> fallback to manual authorized_keys append"

  PUB_B64="$(base64 -w0 "$PUB")"
  REMOTE_CMD=$'set -euo pipefail\n'\
$'export HOME=/root\n'\
$'mkdir -p /root/.ssh\n'\
$'chmod 700 /root/.ssh\n'\
$'touch /root/.ssh/authorized_keys\n'\
$'chmod 600 /root/.ssh/authorized_keys\n'\
$'KEY_LINE="$(echo '"$PUB_B64"' | base64 -d)"\n'\
$'grep -qxF "$KEY_LINE" /root/.ssh/authorized_keys || echo "$KEY_LINE" >> /root/.ssh/authorized_keys\n'\
$'echo "MANUAL_KEY_OK"\n'

  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" \
    -o "PreferredAuthentications=password" \
    -o "PubkeyAuthentication=no" \
    "${USER}@${IP}" "bash -lc $(printf '%q' "$REMOTE_CMD")" \
    || die "Manual key install failed"
fi

# ---- Test key-only login (must NOT ask password) ----
log "[*] Testing key-only login..."
ssh "${SSH_OPTS[@]}" -i "$KEY" \
  -o "PreferredAuthentications=publickey" \
  -o "PubkeyAuthentication=yes" \
  -o "PasswordAuthentication=no" \
  -o "KbdInteractiveAuthentication=no" \
  -o "IdentitiesOnly=yes" \
  "${USER}@${IP}" "echo KEY_OK_FROM_${NAME}" \
  || die "Key-only login test failed"

log "[+] DONE"
log "[+] KEY PATH: $KEY"
