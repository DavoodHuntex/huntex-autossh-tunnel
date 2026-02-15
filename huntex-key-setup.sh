#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
# HUNTEX Key Setup (HPN SSH)
# - Generates a unique SSH key per IR server NAME
# - Pushes pubkey to remote HPN SSH server (port 2222)
# - Designed to survive SSH disconnect via systemd-run
# ==============================

# ---- Inputs (env overrides) ----
IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"

# Remote password (no prompt if provided)
PASS="${PASS:-}"

# If set to 1, wipes local keys under /root/.ssh (except authorized_keys)
WIPE_KEYS="${WIPE_KEYS:-0}"

SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

LOG="/var/log/huntex-key-setup_${NAME}.log"

# ---- Run in background via systemd-run (survives SSH drop) ----
if [[ -z "${HUNTEX_BG:-}" ]]; then
  mkdir -p /var/log
  echo "[*] Re-running in background via systemd-run. Logs: ${LOG}"
  systemd-run --unit="huntex-key-setup-${NAME}" --collect --quiet \
    /bin/bash -lc "HUNTEX_BG=1 IP='$IP' PORT='$PORT' USER='$USER' NAME='$NAME' PASS='$PASS' WIPE_KEYS='$WIPE_KEYS' bash '$0' >>'$LOG' 2>&1"
  echo "[+] Started. Follow logs:"
  echo "    tail -f ${LOG}"
  exit 0
fi

echo "==== HUNTEX KEY SETUP (${NAME}) ===="
echo "[i] IP=${IP} PORT=${PORT} USER=${USER}"
echo "[i] KEY=${KEY}"

# ---- Install required tools ----
if ! command -v sshpass >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y sshpass openssh-client
fi

# ---- Ensure SSH dir ----
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---- Optional: wipe old local keys ----
if [[ "$WIPE_KEYS" == "1" ]]; then
  echo "[!] WIPE_KEYS=1 -> Removing old local key files in ${SSH_DIR} (except authorized_keys)"
  # Remove id_* files (both private/public) + known_hosts_* artifacts
  find "$SSH_DIR" -maxdepth 1 -type f \
    \( -name "id_*" -o -name "known_hosts_*" -o -name "ssh-copy-id*" \) \
    ! -name "authorized_keys" \
    -delete || true
fi

rm -f "$KNOWN" || true

# ---- Generate fresh key (always regenerate for this NAME) ----
echo "[*] Generating fresh key for NAME=${NAME}"
rm -f "$KEY" "$PUB" || true
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)"

chmod 600 "$KEY"
chmod 644 "$PUB"

# ---- Password handling ----
if [[ -z "$PASS" ]]; then
  echo "[FATAL] PASS is empty. Provide PASS env var to avoid prompt."
  echo "Example: PASS='YourPass' NAME='filestore-IR-01' IP='x.x.x.x' bash huntex-key-setup.sh"
  exit 1
fi

# ---- Push key to remote ----
echo "[*] Sending key to remote via ssh-copy-id..."
sshpass -p "$PASS" ssh-copy-id \
  -p "$PORT" \
  -i "$PUB" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  "${USER}@${IP}"

# ---- Test key-only login (must NOT ask password) ----
echo "[*] Testing key-only login..."
ssh -p "$PORT" -i "$KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=publickey \
  -o PubkeyAuthentication=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o IdentitiesOnly=yes \
  "${USER}@${IP}" "echo KEY_OK_FROM_${NAME}"

echo "[+] DONE"
echo "[+] KEY PATH: $KEY"
