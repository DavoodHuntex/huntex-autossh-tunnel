#!/usr/bin/env bash
set -Eeuo pipefail

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

log(){ echo "[$(date +'%F %T')] $*"; }

if [[ -z "$PASS" ]]; then
  echo "FATAL: PASS is empty. Example:"
  echo "IP=... PORT=2222 USER=root NAME=... PASS='xxx' WIPE_KEYS=1 bash $0"
  exit 1
fi

# tools
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y openssh-client sshpass >/dev/null 2>&1 || true

# ensure ssh dir
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# optional wipe (local only)
if [[ "$WIPE_KEYS" == "1" ]]; then
  log "[!] WIPE_KEYS=1 -> removing local id_* + known_hosts_* + ssh-copy-id* (keeping authorized_keys)"
  find "$SSH_DIR" -maxdepth 1 -type f \
    \( -name "id_*" -o -name "known_hosts*" -o -name "ssh-copy-id*" \) \
    ! -name "authorized_keys" -delete || true
fi

# always reset key for this NAME
rm -f "$KEY" "$PUB" "$KNOWN" || true

log "[*] Generating key: $KEY"
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null
chmod 600 "$KEY"
chmod 644 "$PUB"

# aggressive ssh options
SSH_OPTS=(
  -p "$PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile="$KNOWN"
  -o ConnectTimeout=6
  -o ConnectionAttempts=1
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
  -o TCPKeepAlive=yes
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o PasswordAuthentication=yes
  -o KbdInteractiveAuthentication=no
  -o IdentitiesOnly=yes
)

# retry wrapper
retry(){
  local n=0 max=40 delay=1
  until "$@"; do
    n=$((n+1))
    if (( n >= max )); then return 1; fi
    sleep "$delay"
  done
}

log "[*] Installing key on remote (append to authorized_keys)..."

# 1) Ensure remote ~/.ssh and authorized_keys permissions (password auth)
# 2) Append our public key safely (no duplicates)
PUBKEY_CONTENT="$(cat "$PUB")"

install_cmd=$(
  cat <<'EOS'
set -e
umask 077
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
EOS
)

append_cmd=$(
  cat <<EOS
grep -qxF '$PUBKEY_CONTENT' /root/.ssh/authorized_keys || echo '$PUBKEY_CONTENT' >> /root/.ssh/authorized_keys
EOS
)

# remote prepare + append with aggressive retry
retry sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@$IP" "$install_cmd" \
  || { log "[FATAL] remote prepare failed after retries"; exit 2; }

retry sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@$IP" "$append_cmd" \
  || { log "[FATAL] append key failed after retries"; exit 3; }

log "[*] Testing key-only login..."
ssh -p "$PORT" -i "$KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o ConnectTimeout=6 \
  -o ConnectionAttempts=2 \
  -o ServerAliveInterval=10 \
  -o ServerAliveCountMax=2 \
  -o PreferredAuthentications=publickey \
  -o PubkeyAuthentication=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o IdentitiesOnly=yes \
  "$USER@$IP" "echo KEY_OK_FROM_${NAME}" \
  || { log "[FATAL] key-only login test failed"; exit 4; }

log "[+] DONE"
log "[+] KEY PATH: $KEY"
