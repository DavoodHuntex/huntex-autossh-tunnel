#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
# HUNTEX Key Setup (HPN SSH)
# - Unique key per NAME
# - Push pubkey to remote HPN SSH server
# - Survives SSH disconnect using systemd-run
# - SAFE with curl | bash (self-saves first)
# ==============================

IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"

SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

UNIT="huntex-key-setup-${NAME}"
LOG="/var/log/huntex-key-setup_${NAME}.log"
SAVED="/usr/local/bin/${UNIT}.sh"

fatal() { echo "[FATAL] $*" >&2; exit 1; }

# ---- If executed via stdin (curl | bash), save to disk first ----
if [[ ! -f "${BASH_SOURCE[0]}" || "${BASH_SOURCE[0]}" == "/dev/fd/"* ]]; then
  mkdir -p /usr/local/bin /var/log
  cat >"$SAVED"
  chmod 700 "$SAVED"
  exec /bin/bash -lc "IP='$IP' PORT='$PORT' USER='$USER' NAME='$NAME' PASS='$PASS' WIPE_KEYS='$WIPE_KEYS' '$SAVED'"
fi

# ---- Run in background via systemd-run (survives SSH drop) ----
if [[ -z "${HUNTEX_BG:-}" ]]; then
  mkdir -p /var/log
  echo "[*] Re-running in background via systemd-run. Logs: ${LOG}"

  systemctl stop "${UNIT}.service" 2>/dev/null || true
  systemctl reset-failed "${UNIT}.service" 2>/dev/null || true

  systemd-run --unit="${UNIT}" --collect --quiet \
    /bin/bash -lc "
      set -Eeuo pipefail
      export HUNTEX_BG=1
      export IP='${IP}' PORT='${PORT}' USER='${USER}' NAME='${NAME}' PASS='${PASS}' WIPE_KEYS='${WIPE_KEYS}'
      /bin/bash '${SAVED}' >>'${LOG}' 2>&1
    "

  echo "[+] Started. Follow logs:"
  echo "    tail -f ${LOG}"
  exit 0
fi

echo "==== HUNTEX KEY SETUP (${NAME}) ===="
echo "[i] IP=${IP} PORT=${PORT} USER=${USER}"
echo "[i] KEY=${KEY}"
echo "[i] KNOWN=${KNOWN}"

[[ -n "$KEY" ]] || fatal "KEY path is empty (bug)"
[[ -n "$KNOWN" ]] || fatal "KNOWN path is empty (bug)"

# ---- Install tools ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y openssh-client sshpass >/dev/null

# ---- Ensure SSH dir ----
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---- Optional wipe ----
if [[ "$WIPE_KEYS" == "1" ]]; then
  echo "[!] WIPE_KEYS=1 -> Removing artifacts for NAME=${NAME}"
  rm -f "$KEY" "$PUB" "$KNOWN" || true
fi

# ---- Generate fresh key ----
echo "[*] Generating fresh key..."
rm -f "$KEY" "$PUB" || true
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null

chmod 600 "$KEY"
chmod 644 "$PUB"

[[ -f "$KEY" ]] || fatal "Key was not created: $KEY"
[[ -f "$PUB" ]] || fatal "Pubkey was not created: $PUB"
[[ -n "$PASS" ]] || fatal "PASS is empty (set PASS=...)"

# ---- Push key ----
echo "[*] Sending key via ssh-copy-id..."
sshpass -p "$PASS" ssh-copy-id \
  -p "$PORT" \
  -i "$PUB" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  "${USER}@${IP}"

# ---- Test ----
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
