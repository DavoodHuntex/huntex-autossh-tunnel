#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#  HUNTEX Key Setup (HPN SSH)
#  - Creates a unique ED25519 key per NAME on IR server
#  - Pushes pubkey to remote HPN-SSH server (PORT, default 2222)
#  - Can run detached via systemd-run to survive SSH disconnects
#
#  Usage (recommended):
#    curl -fsSL <RAW_URL> -o /root/huntex-key-setup.sh && chmod +x /root/huntex-key-setup.sh
#    IP=... PORT=... USER=... NAME=... PASS=... WIPE_KEYS=1 /root/huntex-key-setup.sh
#
#  Inputs (env):
#    IP, PORT, USER, NAME, PASS, WIPE_KEYS (0/1), FORCE_FG (0/1)
# ============================================================

# ---------- Defaults ----------
IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"
FORCE_FG="${FORCE_FG:-0}"          # set 1 to disable systemd-run

# ---------- Paths ----------
SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

UNIT="huntex-key-setup-${NAME}"
LOG="/var/log/huntex-key-setup_${NAME}.log"
STAGED="/usr/local/bin/${UNIT}.sh"

# ---------- Helpers ----------
ts() { date "+%F %T"; }
log() { echo "[$(ts)] $*"; }
warn() { echo "[$(ts)] [WARN] $*" >&2; }
die() { echo "[$(ts)] [FATAL] $*" >&2; exit 1; }

need_root() {
  [[ "${EUID:-0}" -eq 0 ]] || die "Run as root (sudo)."
}

# Make sure we are not inside a deleted directory (common after rm -rf /root/.ssh while cwd is there)
safe_cwd() {
  cd / || true
  cd /root || true
}

# Run a command but never break the whole script unless we decide
try() {
  set +e
  "$@"
  local rc=$?
  set -e
  return $rc
}

install_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  # Avoid dpkg lock issues from parallel apt
  for i in {1..60}; do
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
      sleep 1
    else
      break
    fi
  done

  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y openssh-client sshpass >/dev/null 2>&1 || true

  command -v sshpass >/dev/null 2>&1 || die "sshpass install failed"
  command -v ssh-copy-id >/dev/null 2>&1 || die "ssh-copy-id missing (openssh-client install failed)"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen missing"
}

ensure_dirs() {
  mkdir -p /var/log >/dev/null 2>&1 || true
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR" || true
}

wipe_local_artifacts() {
  # Only wipe our artifacts, NOT /root/.ssh entirely.
  # We NEVER delete authorized_keys.
  log "[!] WIPE_KEYS=1 -> wiping local key artifacts for NAME=${NAME}"
  rm -f "$KEY" "$PUB" "$KNOWN" 2>/dev/null || true
  # wipe common leftovers, but keep authorized_keys and known_hosts (global) intact
  find "$SSH_DIR" -maxdepth 1 -type f \
    \( -name "known_hosts_${NAME}" -o -name "ssh-copy-id*" \) \
    ! -name "authorized_keys" -delete 2>/dev/null || true
}

generate_key() {
  rm -f "$KEY" "$PUB" 2>/dev/null || true
  log "[*] Generating ED25519 key: $KEY"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null 2>&1 || die "ssh-keygen failed"
  chmod 600 "$KEY" || true
  chmod 644 "$PUB" || true
  [[ -s "$KEY" ]] || die "Key not created: $KEY"
  [[ -s "$PUB" ]] || die "Pubkey not created: $PUB"
}

push_key() {
  [[ -n "$PASS" ]] || die "PASS is empty. Provide PASS=... (no interactive prompt in this script)."
  log "[*] Pushing pubkey to remote ${USER}@${IP}:${PORT} ..."
  # Use StrictHostKeyChecking=no + per-name known_hosts file (isolated)
  sshpass -p "$PASS" ssh-copy-id \
    -p "$PORT" \
    -i "$PUB" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$KNOWN" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${USER}@${IP}" >/dev/null 2>&1 || die "ssh-copy-id failed (wrong PASS/port/IP? remote down?)"
}

test_key_login() {
  log "[*] Testing key-only login (must NOT prompt for password)..."
  # If key login fails, exit with clear error.
  ssh -p "$PORT" -i "$KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$KNOWN" \
    -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=10 \
    -o ConnectionAttempts=2 \
    "${USER}@${IP}" "echo KEY_OK_FROM_${NAME}" >/dev/null 2>&1 \
    || die "Key-only SSH test failed (publickey not accepted). Check remote authorized_keys / AllowUsers / PermitRootLogin."
}

# ---------- Self-stage (for curl|bash safety) ----------
self_stage_if_needed() {
  # If executed from stdin (curl | bash), BASH_SOURCE may be /dev/fd/*
  # In that case, save ourselves to disk and exec from disk.
  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "$src" || "$src" == "/dev/fd/"* || "$src" == "/proc/self/fd/"* || ! -f "$src" ]]; then
    ensure_dirs
    log "[*] Running from stdin. Staging script to: $STAGED"
    cat >"$STAGED"
    chmod 700 "$STAGED"
    exec /bin/bash -lc "IP='$IP' PORT='$PORT' USER='$USER' NAME='$NAME' PASS='$PASS' WIPE_KEYS='$WIPE_KEYS' FORCE_FG='$FORCE_FG' '$STAGED'"
  fi

  # If we are running from a file that is NOT our staged path, keep a copy in STAGED
  ensure_dirs
  if [[ "$src" != "$STAGED" ]]; then
    cp -f "$src" "$STAGED" 2>/dev/null || true
    chmod 700 "$STAGED" 2>/dev/null || true
  fi
}

# ---------- Background runner ----------
maybe_background() {
  # If already in background, continue
  if [[ "${HUNTEX_BG:-0}" == "1" ]]; then
    return 0
  fi

  # If forced foreground, continue
  if [[ "$FORCE_FG" == "1" ]]; then
    warn "FORCE_FG=1 -> running in foreground (no systemd-run)."
    return 0
  fi

  # If systemd-run exists, run detached and exit
  if command -v systemd-run >/dev/null 2>&1; then
    ensure_dirs
    safe_cwd

    # Stop any previous unit
    try systemctl stop "${UNIT}.service" >/dev/null 2>&1 || true
    try systemctl reset-failed "${UNIT}.service" >/dev/null 2>&1 || true

    log "[*] Starting detached via systemd-run. Log: $LOG"
    # IMPORTANT: do NOT run "bash '$0'" (can be empty). Always run staged file.
    systemd-run --unit="$UNIT" --collect --quiet \
      /bin/bash -lc "
        set -Eeuo pipefail
        export HUNTEX_BG=1
        export IP='${IP}' PORT='${PORT}' USER='${USER}' NAME='${NAME}' PASS='${PASS}' WIPE_KEYS='${WIPE_KEYS}' FORCE_FG='1'
        exec /bin/bash '${STAGED}' >>'${LOG}' 2>&1
      " || warn "systemd-run failed; falling back to foreground."

    # If systemd-run succeeded, show follow command and exit
    if systemctl status "${UNIT}.service" >/dev/null 2>&1; then
      echo "[+] Started."
      echo "    tail -f ${LOG}"
      exit 0
    fi
  fi

  # Fallback: continue in foreground
  warn "systemd-run not available or failed -> running in foreground."
}

main_fg() {
  safe_cwd
  ensure_dirs

  # Print header
  log "==== HUNTEX KEY SETUP (${NAME}) ===="
  log "[i] IP=${IP} PORT=${PORT} USER=${USER}"
  log "[i] KEY=${KEY}"
  log "[i] KNOWN=${KNOWN}"
  log "[i] WIPE_KEYS=${WIPE_KEYS}"

  # Sanity
  [[ -n "$NAME" ]] || die "NAME is empty"
  [[ -n "$IP" ]] || die "IP is empty"
  [[ -n "$PORT" ]] || die "PORT is empty"
  [[ -n "$USER" ]] || die "USER is empty"

  install_pkgs

  if [[ "$WIPE_KEYS" == "1" ]]; then
    wipe_local_artifacts
  fi

  generate_key
  push_key
  test_key_login

  log "[+] DONE"
  log "[+] KEY PATH: $KEY"
}

# ---------- Entry ----------
need_root
self_stage_if_needed
maybe_background
main_fg
