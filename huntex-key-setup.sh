#!/usr/bin/env bash
set -Eeuo pipefail

IP="${IP:-46.226.162.4}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"

SSH_DIR="/root/.ssh"

log(){ echo "[$(date +'%F %T')] $*"; }
die(){ log "[FATAL] $*"; exit 1; }

[[ -n "$PASS" ]] || die "PASS is empty. Example: IP=... PASS='xxx' WIPE_KEYS=1 bash"

# ---- NAME = iran-[hostname] ----
HN="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
NAME="iran-${HN}"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

# ---- deps (quiet, no-fail hard) ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y openssh-client sshpass >/dev/null 2>&1 || true

# ---- ensure ssh dir ----
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---- optional wipe (local only) ----
if [[ "$WIPE_KEYS" == "1" ]]; then
  log "[!] WIPE_KEYS=1 -> removing local id_* + known_hosts_* (keeping authorized_keys)"
  find "$SSH_DIR" -maxdepth 1 -type f \
    \( -name "id_*" -o -name "known_hosts*" \) \
    ! -name "authorized_keys" -delete || true
fi

log "[*] Using NAME=${NAME}"
rm -f "$KEY" "$PUB" "$KNOWN" || true

log "[*] Generating key: $KEY"
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname -f 2>/dev/null || hostname)" >/dev/null 2>&1 || die "ssh-keygen failed"
chmod 600 "$KEY" || true
chmod 644 "$PUB" || true

# ---- quick TCP check ----
log "[*] Checking TCP port ${PORT} on ${IP}..."
if timeout 5 bash -lc "cat </dev/null >/dev/tcp/${IP}/${PORT}" >/dev/null 2>&1; then
  log "[+] ${PORT} OPEN"
else
  die "${PORT} CLOSED (network/firewall)"
fi

# ---- SSH options (IMPORTANT: -n + stdin=/dev/null to avoid pipe hang) ----
SSH_BASE_OPTS=(
  -n
  -p "$PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile="$KNOWN"
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=7
  -o ConnectionAttempts=1
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=2
  -o TCPKeepAlive=yes
  -o LogLevel=ERROR
)

# for password stage, allow BOTH password + keyboard-interactive (your server needs it)
SSH_PASS_OPTS=(
  -o PreferredAuthentications=password,keyboard-interactive
  -o PasswordAuthentication=yes
  -o KbdInteractiveAuthentication=yes
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
)

retry(){
  local n=0 max=25 delay=1
  until "$@"; do
    n=$((n+1))
    if (( n >= max )); then return 1; fi
    sleep "$delay"
  done
}

PUBKEY_CONTENT="$(cat "$PUB")"

REMOTE_PREP=$'set -e\numask 077\nmkdir -p /root/.ssh\nchmod 700 /root/.ssh\ntouch /root/.ssh/authorized_keys\nchmod 600 /root/.ssh/authorized_keys\n'

REMOTE_APPEND="grep -qxF '$PUBKEY_CONTENT' /root/.ssh/authorized_keys || echo '$PUBKEY_CONTENT' >> /root/.ssh/authorized_keys; echo KEY_ADDED"

log "[*] Installing key on remote (prepare)..."
retry sshpass -p "$PASS" ssh "${SSH_BASE_OPTS[@]}" "${SSH_PASS_OPTS[@]}" "$USER@$IP" "$REMOTE_PREP" \
  || die "remote prepare failed"

log "[*] Installing key on remote (append)..."
retry sshpass -p "$PASS" ssh "${SSH_BASE_OPTS[@]}" "${SSH_PASS_OPTS[@]}" "$USER@$IP" "$REMOTE_APPEND" \
  || die "append key failed"

log "[*] Verifying key-only login..."
ssh "${SSH_BASE_OPTS[@]}" -i "$KEY" \
  -o PreferredAuthentications=publickey \
  -o PubkeyAuthentication=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o IdentitiesOnly=yes \
  "$USER@$IP" "echo KEY_OK && hostname && whoami" \
  || die "key-only login test failed"

log "[+] DONE"
log "[+] KEY PATH: $KEY"
