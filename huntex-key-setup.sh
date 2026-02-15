#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# HUNTEX Key Setup (HPN SSH) - FINAL
# - Works with BOTH:
#     1) curl ... | bash
#     2) curl -o file && chmod +x && ./file
# - Survives SSH disconnect by re-running via systemd-run
# - ALWAYS resets (deletes + recreates) keypair for this NAME
# - Pushes pubkey WITHOUT ssh-copy-id (no mktemp/~/.ssh issues)
# ==========================================================

ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; }
die(){ log "[FATAL] $*"; exit 1; }

# ---------------- Inputs (env) ----------------
IP="${IP:-}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-}"
PASS="${PASS:-}"             # required (no prompt)
WIPE_KEYS="${WIPE_KEYS:-0}"  # 1 => remove only this NAME artifacts (safe)

# ---------------- Paths ----------------
SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"
LOGFILE="/var/log/huntex-key-setup_${NAME}.log"

# ---------------- Validate ----------------
[[ -n "$IP" ]]   || die "IP is required"
[[ -n "$NAME" ]] || die "NAME is required"
[[ -n "$PASS" ]] || die "PASS is required (no prompt mode)"

# ---------------- Self materialization (pipe-safe) ----------------
# If invoked via pipe (curl | bash), $0 is "bash". We MUST save script to a file.
SELF="${SELF_PATH:-}"
if [[ -z "$SELF" ]]; then
  if [[ "${0##*/}" == "bash" || "${0##*/}" == "sh" || ! -f "$0" ]]; then
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

# ---------------- Run in background (systemd-run) ----------------
if [[ -z "${HUNTEX_BG:-}" ]]; then
  mkdir -p /var/log
  log "[*] Re-running in background via systemd-run. Logs: ${LOGFILE}"

  # Run exactly the saved file (SELF_PATH), not "$0"
  systemd-run --unit="huntex-key-setup-${NAME}" --collect --quiet \
    /usr/bin/env \
      HOME=/root \
      IP="$IP" PORT="$PORT" USER="$USER" NAME="$NAME" PASS="$PASS" WIPE_KEYS="$WIPE_KEYS" \
      HUNTEX_BG=1 SELF_PATH="$SELF" \
    /bin/bash -lc "'$SELF' >>'$LOGFILE' 2>&1" \
    || die "systemd-run failed"

  log "[+] Started. Follow logs:"
  log "    tail -f ${LOGFILE}"
  exit 0
fi

# ===================== Real work (background) =====================
log "==== HUNTEX KEY SETUP (${NAME}) ===="
log "[i] IP=${IP} PORT=${PORT} USER=${USER}"
log "[i] HOME=${HOME}"
log "[i] KEY=${KEY}"

# Tools
if ! command -v sshpass >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
  log "[*] Installing deps..."
  apt-get update -y
  apt-get install -y sshpass openssh-client
fi

# Ensure /root & ssh dir
mkdir -p /root
chmod 700 /root || true
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Optional wipe (SAFE): only this NAME artifacts
if [[ "$WIPE_KEYS" == "1" ]]; then
  log "[!] WIPE_KEYS=1 -> Removing ONLY this NAME key artifacts"
  rm -f "$KEY" "$PUB" "$KNOWN" || true
fi

# Always reset keypair for NAME (this guarantees script #2 consistency)
log "[*] Resetting keypair for NAME=${NAME} (delete + create fresh)"
rm -f "$KEY" "$PUB" || true
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)"
chmod 600 "$KEY"
chmod 644 "$PUB"

# Push key without ssh-copy-id
log "[*] Pushing public key to remote authorized_keys (password auth)"
PUB_LINE="$(cat "$PUB")"

sshpass -p "$PASS" ssh -p "$PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o PasswordAuthentication=yes \
  -o KbdInteractiveAuthentication=no \
  "${USER}@${IP}" \
  "set -e
   umask 077
   mkdir -p ~/.ssh
   chmod 700 ~/.ssh
   touch ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   grep -qxF '$PUB_LINE' ~/.ssh/authorized_keys || echo '$PUB_LINE' >> ~/.ssh/authorized_keys
   echo REMOTE_KEY_INSTALLED"

# Test key-only login
log "[*] Testing key-only login (must not prompt password)"
ssh -p "$PORT" -i "$KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=publickey \
  -o PubkeyAuthentication=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o IdentitiesOnly=yes \
  "${USER}@${IP}" "echo KEY_OK_FROM_${NAME}"

log "[+] DONE"
log "[+] KEY PATH: ${KEY}"
