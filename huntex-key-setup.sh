#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
# HUNTEX Key Setup (HPN SSH)
# - Generates a unique SSH key per IR server NAME
# - Pushes pubkey to remote HPN SSH server (port 2222)
# - Survives SSH disconnect by re-running via systemd-run
# - Works correctly even when executed via: curl ... | bash
# ==============================

# ---- Inputs (env overrides) ----
IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"

# Remote password (no prompt if provided)
PASS="${PASS:-}"

# If set to 1, wipes local key artifacts (scoped/safe)
WIPE_KEYS="${WIPE_KEYS:-0}"

SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

UNIT="huntex-key-setup-${NAME}"
LOG="/var/log/huntex-key-setup_${NAME}.log"

# ---- Helper: ensure we run from a real file (important for curl | bash) ----
ensure_script_on_disk() {
  # If already running from a regular file, keep it.
  if [[ -f "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != "/dev/fd/"* ]]; then
    echo "${BASH_SOURCE[0]}"
    return 0
  fi

  # We are likely running from stdin (curl | bash). Save ourselves to a file.
  mkdir -p /usr/local/bin
  local saved="/usr/local/bin/${UNIT}.sh"
  cat >"$saved"
  chmod 700 "$saved"
  echo "$saved"
}

# ---- Background mode (systemd-run) ----
if [[ -z "${HUNTEX_BG:-}" ]]; then
  mkdir -p /var/log

  # Save script to disk if needed (so systemd can execute it)
  SCRIPT_PATH="$(ensure_script_on_disk)"

  echo "[*] Re-running in background via systemd-run. Logs: ${LOG}"
  # Stop any previous run for same unit (avoid duplicates)
  systemctl stop "${UNIT}.service" 2>/dev/null || true
  systemctl reset-failed "${UNIT}.service" 2>/dev/null || true

  systemd-run --unit="${UNIT}" --collect --quiet \
    /bin/bash -lc "
      set -Eeuo pipefail
      export HUNTEX_BG=1
      export IP='${IP}' PORT='${PORT}' USER='${USER}' NAME='${NAME}' PASS='${PASS}' WIPE_KEYS='${WIPE_KEYS}'
      /bin/bash '${SCRIPT_PATH}' >>'${LOG}' 2>&1
    "

  echo "[+] Started. Follow logs:"
  echo "    tail -f ${LOG}"
  exit 0
fi

# ---- Actual work starts here ----
echo "==== HUNTEX KEY SETUP (${NAME}) ===="
echo "[i] IP=${IP} PORT=${PORT} USER=${USER}"
echo "[i] KEY=${KEY}"

# ---- Install required tools ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y openssh-client sshpass >/dev/null

# ---- Ensure SSH dir ----
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---- Optional: wipe key artifacts (SAFE & scoped) ----
if [[ "$WIPE_KEYS" == "1" ]]; then
  echo "[!] WIPE_KEYS=1 -> Removing key artifacts for this NAME only"
  rm -f "$KEY" "$PUB" "$KNOWN" || true
  # Also remove stale hashed hostkey entries (non-fatal if files missing)
  ssh-keygen -R "[${IP}]:${PORT}" -f "$KNOWN" >/dev/null 2>&1 || true
fi

# ---- Generate fresh key for this NAME (always regenerate) ----
echo "[*] Generating fresh key for NAME=${NAME}"
rm -f "$KEY" "$PUB" || true
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null

chmod 600 "$KEY"
chmod 644 "$PUB"

# ---- Password handling ----
if [[ -z "$PASS" ]]; then
  echo "[FATAL] PASS is empty. Provide PASS env var (no prompt mode)."
  echo "Example:"
  echo "  IP='x.x.x.x' PORT='2222' USER='root' NAME='filestore-IR-01' PASS='YourPass' WIPE_KEYS='1' bash huntex-key-setup.sh"
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
