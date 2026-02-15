#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# HUNTEX Key Setup (HPN SSH) - NO ERROR VERSION
# - Forces HOME=/root in systemd-run environments
# - WIPE_KEYS=1 wipes only this NAME artifacts
# - Tries ssh-copy-id first, falls back to manual authorized_keys append
# - Can run detached via systemd-run (survives SSH disconnect)
# ============================================================

IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"
FORCE_FG="${FORCE_FG:-0}"

# ---- Hard force root HOME (fixes ssh-copy-id "~/.ssh" mktemp bug) ----
export HOME="/root"
export USER="root"
export LOGNAME="root"
export SHELL="/bin/bash"
export TMPDIR="/tmp"
umask 077

SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

UNIT="huntex-key-setup-${NAME}"
LOG="/var/log/huntex-key-setup_${NAME}.log"
STAGED="/usr/local/bin/${UNIT}.sh"

ts(){ date "+%F %T"; }
log(){ echo "[$(ts)] $*"; }
die(){ echo "[$(ts)] [FATAL] $*" >&2; exit 1; }

need_root(){ [[ "${EUID:-0}" -eq 0 ]] || die "Run as root (sudo)."; }
safe_cwd(){ cd /root 2>/dev/null || cd / || true; }

try(){ set +e; "$@"; local rc=$?; set -e; return $rc; }

ensure_dirs(){
  mkdir -p /var/log /usr/local/bin /tmp || true
  chmod 1777 /tmp || true
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR" || true
  chown root:root "$SSH_DIR" || true
}

install_tools(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y openssh-client sshpass >/dev/null 2>&1 || true
  command -v sshpass >/dev/null 2>&1 || die "sshpass install failed"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen missing"
  command -v ssh >/dev/null 2>&1 || die "ssh missing"
}

stage_self(){
  safe_cwd
  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "$src" || "$src" == "/dev/fd/"* || "$src" == "/proc/"* || ! -f "$src" ]]; then
    log "[*] Running from stdin -> staging to $STAGED"
    cat >"$STAGED"
    chmod 700 "$STAGED"
    exec /usr/bin/env bash "$STAGED"
  fi
  cp -f "$src" "$STAGED" 2>/dev/null || true
  chmod 700 "$STAGED" 2>/dev/null || true
}

maybe_background(){
  if [[ "${HUNTEX_BG:-0}" == "1" ]]; then return 0; fi
  if [[ "$FORCE_FG" == "1" ]]; then return 0; fi

  if command -v systemd-run >/dev/null 2>&1; then
    safe_cwd
    log "[*] Re-running in background via systemd-run. Logs: $LOG"

    try systemctl stop "${UNIT}.service" >/dev/null 2>&1 || true
    try systemctl reset-failed "${UNIT}.service" >/dev/null 2>&1 || true

    systemd-run --unit="$UNIT" --collect --quiet \
      /usr/bin/env bash -c "
        set -Eeuo pipefail
        export HUNTEX_BG=1 FORCE_FG=1
        export HOME=/root USER=root LOGNAME=root SHELL=/bin/bash TMPDIR=/tmp
        export IP='${IP}' PORT='${PORT}' USER_REMOTE='${USER}' NAME='${NAME}' PASS='${PASS}' WIPE_KEYS='${WIPE_KEYS}'
        cd /root || true
        /usr/bin/env bash '${STAGED}' >>'${LOG}' 2>&1
      " || true

    # If systemd-run worked, exit. If not, continue foreground.
    if systemctl is-active --quiet "${UNIT}.service" 2>/dev/null; then
      echo "[+] Started. Follow logs:"
      echo "    tail -f ${LOG}"
      exit 0
    fi
  fi
}

wipe_name_only(){
  log "[!] WIPE_KEYS=1 -> Removing key artifacts for this NAME only"
  rm -f "$KEY" "$PUB" "$KNOWN" 2>/dev/null || true
}

generate_key(){
  ensure_dirs
  rm -f "$KEY" "$PUB" 2>/dev/null || true
  log "[*] Generating fresh key for NAME=${NAME}"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null 2>&1 \
    || die "ssh-keygen failed"
  chmod 600 "$KEY" || true
  chmod 644 "$PUB" || true
  [[ -s "$KEY" && -s "$PUB" ]] || die "Key generation failed"
}

push_key_copyid(){
  # Try ssh-copy-id (may fail on some systems with ~/.ssh mktemp)
  if ! command -v ssh-copy-id >/dev/null 2>&1; then
    return 1
  fi

  log "[*] Sending key via ssh-copy-id..."
  # Force HOME so "~/.ssh" resolves
  HOME=/root TMPDIR=/tmp sshpass -p "$PASS" ssh-copy-id \
    -p "$PORT" \
    -i "$PUB" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$KNOWN" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${USER}@${IP}" >/dev/null 2>&1
}

push_key_fallback(){
  # 100% reliable: append pubkey to authorized_keys on remote
  log "[*] ssh-copy-id failed -> using fallback (manual authorized_keys append)..."
  local pub
  pub="$(cat "$PUB")"
  [[ -n "$pub" ]] || die "PUB empty"

  HOME=/root TMPDIR=/tmp sshpass -p "$PASS" ssh \
    -p "$PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$KNOWN" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${USER}@${IP}" \
    "set -e;
     mkdir -p /root/.ssh;
     chmod 700 /root/.ssh;
     touch /root/.ssh/authorized_keys;
     chmod 600 /root/.ssh/authorized_keys;
     grep -qxF '$pub' /root/.ssh/authorized_keys || echo '$pub' >> /root/.ssh/authorized_keys" >/dev/null 2>&1 \
    || die "Fallback push failed"
}

test_key(){
  log "[*] Testing key-only login..."
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
    || die "Key-only test failed"
}

main(){
  need_root
  ensure_dirs
  stage_self
  maybe_background

  # In systemd-run we passed USER_REMOTE to avoid clobbering USER=root env
  if [[ -n "${USER_REMOTE:-}" ]]; then
    USER="$USER_REMOTE"
  fi

  log "==== HUNTEX KEY SETUP (${NAME}) ===="
  log "[i] IP=${IP} PORT=${PORT} USER=${USER}"
  log "[i] KEY=${KEY}"

  [[ -n "$PASS" ]] || die "PASS is empty. Provide PASS=..."

  install_tools
  ensure_dirs

  if [[ "$WIPE_KEYS" == "1" ]]; then
    wipe_name_only
    ensure_dirs
  fi

  generate_key

  if ! push_key_copyid; then
    push_key_fallback
  fi

  test_key

  log "[+] DONE"
  log "[+] KEY PATH: $KEY"
}

main
