#!/usr/bin/env bash
set -Eeuo pipefail

IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"

SSH_DIR="/root/.ssh"

# Build NAME from *local* hostname (exactly as requested)
HOST_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
HOST_SAFE="$(echo "$HOST_SHORT" | tr -cd 'A-Za-z0-9._-')"
NAME="iran-${HOST_SAFE}"

KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

log(){ echo "[$(date +'%F %T')] $*"; }

die(){
  log "FATAL: $*"
  exit 1
}

if [[ -z "$PASS" ]]; then
  cat >&2 <<EOF
FATAL: PASS is empty.
Example:
curl -fsSL https://raw.githubusercontent.com/DavoodHuntex/huntex-autossh-tunnel/main/huntex-key-setup.sh | \\
IP="45.144.55.47" PORT="2222" USER="root" PASS="Davood@123" WIPE_KEYS="1" bash
EOF
  exit 1
fi

# Install tools (best-effort + no noisy output)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true

# openssh-client provides ssh/ssh-keygen/ssh-copy-id, sshpass provides password automation
apt-get install -y openssh-client sshpass >/dev/null 2>&1 || true

command -v ssh >/dev/null 2>&1 || die "ssh not found even after install."
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found even after install."
command -v sshpass >/dev/null 2>&1 || die "sshpass not found even after install."

# Ensure ~/.ssh
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Optional local wipe
if [[ "$WIPE_KEYS" == "1" ]]; then
  log "[!] WIPE_KEYS=1 -> removing local id_* + known_hosts_* + ssh-copy-id* (keeping authorized_keys)"
  find "$SSH_DIR" -maxdepth 1 -type f \
    \( -name "id_*" -o -name "known_hosts*" -o -name "ssh-copy-id*" \) \
    ! -name "authorized_keys" -delete >/dev/null 2>&1 || true
fi

# Reset files for this NAME
rm -f "$KEY" "$PUB" "$KNOWN" >/dev/null 2>&1 || true

log "[*] Using NAME=${NAME}"
log "[*] Generating key: $KEY"
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname 2>/dev/null || echo host)" >/dev/null 2>&1 || die "ssh-keygen failed."
chmod 600 "$KEY" >/dev/null 2>&1 || true
chmod 644 "$PUB" >/dev/null 2>&1 || true

# SSH options (match your working case: allow kbd-interactive too)
SSH_OPTS=(
  -p "$PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile="$KNOWN"
  -o ConnectTimeout=7
  -o ConnectionAttempts=1
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
  -o TCPKeepAlive=yes
  -o PreferredAuthentications=password,keyboard-interactive
  -o PubkeyAuthentication=no
  -o PasswordAuthentication=yes
  -o KbdInteractiveAuthentication=yes
  -o IdentitiesOnly=yes
)

retry(){
  local n=0 max=40 delay=1
  until "$@"; do
    n=$((n+1))
    if (( n >= max )); then
      return 1
    fi
    sleep "$delay"
  done
}

log "[*] Checking TCP port ${PORT} on ${IP}..."
timeout 6 bash -lc "cat </dev/null >/dev/tcp/${IP}/${PORT}" >/dev/null 2>&1 \
  && log "[+] ${PORT} OPEN" \
  || log "[!] ${PORT} check failed (may still be reachable). Continuing..."

PUBKEY_CONTENT="$(cat "$PUB")"

# Remote prep (root assumed)
remote_prep_cmd=$'set -e\numask 077\nmkdir -p /root/.ssh\nchmod 700 /root/.ssh\ntouch /root/.ssh/authorized_keys\nchmod 600 /root/.ssh/authorized_keys\n'

# Append key without duplicates (safe)
# Use printf to avoid echo weirdness
remote_append_cmd=$(cat <<EOF
grep -qxF '$PUBKEY_CONTENT' /root/.ssh/authorized_keys || printf '%s\n' '$PUBKEY_CONTENT' >> /root/.ssh/authorized_keys
EOF
)

log "[*] Installing key on remote (prepare)..."
retry sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@$IP" "$remote_prep_cmd" \
  || die "remote prepare failed after retries."

log "[*] Installing key on remote (append authorized_keys)..."
retry sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@$IP" "$remote_append_cmd" \
  || die "append key failed after retries."

log "[*] Testing KEY-ONLY login..."
ssh -p "$PORT" -i "$KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$KNOWN" \
  -o ConnectTimeout=7 \
  -o ConnectionAttempts=2 \
  -o ServerAliveInterval=10 \
  -o ServerAliveCountMax=2 \
  -o PreferredAuthentications=publickey \
  -o PubkeyAuthentication=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o IdentitiesOnly=yes \
  "$USER@$IP" "echo KEY_OK_FROM_${NAME} && hostname && whoami" \
  >/dev/null 2>&1 || die "key-only login test failed."

log "[+] DONE"
log "[+] KEY PATH: $KEY"
log "[+] KNOWN_HOSTS: $KNOWN"
