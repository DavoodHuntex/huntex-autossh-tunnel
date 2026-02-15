#!/usr/bin/env bash
set -Eeuo pipefail

# Inputs (env override friendly)
IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"
PASS="${PASS:-}"                 # MUST be provided for non-interactive runs
WIPE_THIS_NAME="${WIPE_THIS_NAME:-1}"

export HOME="${HOME:-/root}"

SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

echo "==== HUNTEX KEY RESET (${NAME}) ===="
echo "[i] IP=${IP} PORT=${PORT} USER=${USER}"
echo "[i] KEY=${KEY}"

# Tools
if ! command -v sshpass >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y sshpass openssh-client
fi

# SSH dir
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Safety: only wipe THIS NAME artifacts (not all keys!)
if [[ "$WIPE_THIS_NAME" == "1" ]]; then
  rm -f "$KEY" "$PUB" "$KNOWN" || true
fi

# Generate fresh key
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)"
chmod 600 "$KEY"
chmod 644 "$PUB"

# PASS required for non-interactive
if [[ -z "$PASS" ]]; then
  echo "[FATAL] PASS is empty. Run like:"
  echo "PASS='YourPass' IP='x.x.x.x' PORT='2222' USER='root' NAME='${NAME}' bash $0"
  exit 1
fi

# Install pubkey on remote (NO ssh-copy-id)
echo "[*] Installing key on remote (append to authorized_keys)..."
timeout 25 sshpass -p "$PASS" ssh \
  -p "$PORT" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o PasswordAuthentication=yes \
  -o KbdInteractiveAuthentication=no \
  -o ConnectTimeout=10 \
  -o ConnectionAttempts=2 \
  "${USER}@${IP}" \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'

# Append key (idempotent-ish: avoid duplicates)
PUBKEY_LINE="$(cat "$PUB")"
timeout 25 sshpass -p "$PASS" ssh \
  -p "$PORT" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o PasswordAuthentication=yes \
  -o KbdInteractiveAuthentication=no \
  -o ConnectTimeout=10 \
  -o ConnectionAttempts=2 \
  "${USER}@${IP}" \
  "grep -qxF '$PUBKEY_LINE' ~/.ssh/authorized_keys || echo '$PUBKEY_LINE' >> ~/.ssh/authorized_keys"

# Test key-only login
echo "[*] Testing key-only login..."
timeout 20 ssh \
  -p "$PORT" -i "$KEY" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=publickey \
  -o PubkeyAuthentication=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o IdentitiesOnly=yes \
  -o ConnectTimeout=10 \
  -o ConnectionAttempts=2 \
  "${USER}@${IP}" "echo KEY_OK_FROM_${NAME}"

echo "[+] DONE"
echo "[+] KEY PATH: $KEY"
