#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
# HUNTEX Aggressive Key Setup
# - Generates per-NAME ed25519 key under /root/.ssh
# - Installs pubkey on remote by direct append (NO ssh-copy-id)
# - Aggressive retry to survive flaky SSH/network
# ==============================

IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"
PASS="${PASS:-}"          # required (no prompt)
WIPE_KEYS="${WIPE_KEYS:-0}"

SSH_DIR="${SSH_DIR:-/root/.ssh}"
KEY="${KEY:-${SSH_DIR}/id_ed25519_${NAME}}"
PUB="${PUB:-${KEY}.pub}"
KNOWN="${KNOWN:-${SSH_DIR}/known_hosts_${NAME}}"

# Aggressive connection defaults
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-7}"
ALIVE_INTERVAL="${ALIVE_INTERVAL:-10}"
ALIVE_COUNT="${ALIVE_COUNT:-2}"
ATTEMPTS="${ATTEMPTS:-40}"        # total retry attempts
SLEEP_BASE="${SLEEP_BASE:-1}"     # base sleep seconds (backoff grows)

export HOME="/root"
export TMPDIR="/tmp"

log(){ echo "[$(date '+%F %T')] $*"; }

need_root(){
  if [[ "${EUID}" -ne 0 ]]; then
    echo "FATAL: run as root" >&2
    exit 1
  fi
}

install_tools(){
  command -v ssh >/dev/null 2>&1 || { apt-get update -y; apt-get install -y openssh-client; }
  command -v sshpass >/dev/null 2>&1 || { apt-get update -y; apt-get install -y sshpass; }
}

ensure_dirs(){
  mkdir -p "$SSH_DIR" /tmp
  chmod 700 "$SSH_DIR"
  chmod 1777 /tmp || true
}

wipe_local(){
  if [[ "$WIPE_KEYS" == "1" ]]; then
    log "[!] WIPE_KEYS=1 -> removing local id_* + known_hosts_* + sshpass temp artifacts (keeping authorized_keys)"
    find "$SSH_DIR" -maxdepth 1 -type f \
      \( -name "id_*" -o -name "known_hosts_*" -o -name "ssh-copy-id*" \) \
      ! -name "authorized_keys" -delete || true
  fi
}

gen_key(){
  # Always (re)create key for this NAME to avoid stale/mismatch
  rm -f "$KEY" "$PUB" || true
  log "[*] Generating key: $KEY"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null
  chmod 600 "$KEY"
  chmod 644 "$PUB"
}

ssh_opts_common=(
  -p "$PORT"
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=$KNOWN"
  -o "ConnectTimeout=$CONNECT_TIMEOUT"
  -o "ConnectionAttempts=1"
  -o "ServerAliveInterval=$ALIVE_INTERVAL"
  -o "ServerAliveCountMax=$ALIVE_COUNT"
  -o "TCPKeepAlive=yes"
  -o "IdentitiesOnly=yes"
  -o "LogLevel=ERROR"
)

# retry wrapper
retry(){
  local n=1
  local cmd_desc="$1"; shift
  while true; do
    if "$@"; then
      return 0
    fi
    if (( n >= ATTEMPTS )); then
      log "[FATAL] Failed after ${ATTEMPTS} attempts: ${cmd_desc}"
      return 1
    fi
    # exponential-ish backoff capped at 15s
    local sleep_s=$(( SLEEP_BASE + (n/3) ))
    (( sleep_s > 15 )) && sleep_s=15
    log "[!] ${cmd_desc} failed (attempt $n/${ATTEMPTS}) -> retry in ${sleep_s}s"
    sleep "$sleep_s"
    ((n++))
  done
}

remote_prepare(){
  # Ensure remote .ssh + authorized_keys perms are correct
  sshpass -p "$PASS" ssh "${ssh_opts_common[@]}" \
    -o "PreferredAuthentications=password" \
    -o "PubkeyAuthentication=no" \
    -o "PasswordAuthentication=yes" \
    "${USER}@${IP}" \
    "mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
}

remote_append_key(){
  # Append pubkey (idempotent-ish): only add if not already present
  local pubkey
  pubkey="$(cat "$PUB")"
  # Use a safe grep check on remote, then append
  sshpass -p "$PASS" ssh "${ssh_opts_common[@]}" \
    -o "PreferredAuthentications=password" \
    -o "PubkeyAuthentication=no" \
    -o "PasswordAuthentication=yes" \
    "${USER}@${IP}" \
    "grep -qxF '$pubkey' /root/.ssh/authorized_keys || echo '$pubkey' >> /root/.ssh/authorized_keys"
}

test_key_login(){
  ssh "${ssh_opts_common[@]}" \
    -i "$KEY" \
    -o "PreferredAuthentications=publickey" \
    -o "PubkeyAuthentication=yes" \
    -o "PasswordAuthentication=no" \
    -o "KbdInteractiveAuthentication=no" \
    "${USER}@${IP}" "echo KEY_OK_FROM_${NAME}"
}

main(){
  need_root
  if [[ -z "$PASS" ]]; then
    echo "FATAL: PASS is required (set PASS=...)" >&2
    exit 1
  fi

  install_tools
  ensure_dirs
  wipe_local
  gen_key

  log "[*] Remote prepare..."
  retry "remote_prepare" remote_prepare

  log "[*] Installing key on remote (append)..."
  retry "remote_append_key" remote_append_key

  log "[*] Testing key-only login..."
  retry "test_key_login" test_key_login

  log "[+] DONE"
  log "[+] KEY: $KEY"
  log "[+] KNOWN_HOSTS: $KNOWN"
}

main "$@"
