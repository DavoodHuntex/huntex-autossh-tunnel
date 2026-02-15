#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# HUNTEX Key Setup (HPN SSH)
# - Safe with WIPE_KEYS=1 (only wipes this NAME artifacts)
# - Fixes ssh-copy-id mktemp failure by enforcing ~/.ssh and TMPDIR=/tmp
# - Can run detached via systemd-run (survives SSH disconnect)
# ============================================================

IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"
FORCE_FG="${FORCE_FG:-0}"

SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

UNIT="huntex-key-setup-${NAME}"
LOG="/var/log/huntex-key-setup_${NAME}.log"
STAGED="/usr/local/bin/${UNIT}.sh"

ts(){ date "+%F %T"; }
log(){ echo "[$(ts)] $*"; }
warn(){ echo "[$(ts)] [WARN] $*" >&2; }
die(){ echo "[$(ts)] [FATAL] $*" >&2; exit 1; }
need_root(){ [[ "${EUID:-0}" -eq 0 ]] || die "Run as root (sudo)."; }

safe_cwd(){ cd /root 2>/dev/null || cd / || true; }

try(){ set +e; "$@"; local rc=$?; set -e; return $rc; }

ensure_ssh_dir(){
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR" || true
  # Ensure root owns it (common after accidental deletes/recreates)
  chown root:root "$SSH_DIR" || true
}

install_tools(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y openssh-client sshpass >/dev/null 2>&1 || true
  command -v sshpass >/dev/null 2>&1 || die "sshpass install failed"
  command -v ssh-copy-id >/dev/null 2>&1 || die "ssh-copy-id missing"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen missing"
}

stage_self(){
  mkdir -p /var/log >/dev/null 2>&1 || true
  safe_cwd

  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "$src" || "$src" == "/dev/fd/"* || "$src" == "/proc/"* || ! -f "$src" ]]; then
    log "[*] Running from stdin -> staging to $STAGED"
    mkdir -p /usr/local/bin >/dev/null 2>&1 || true
    cat >"$STAGED"
    chmod 700 "$STAGED"
    exec /usr/bin/env bash "$STAGED"
  fi

  mkdir -p /usr/local/bin >/dev/null 2>&1 || true
  cp -f "$src" "$STAGED" 2>/dev/null || true
  chmod 700 "$STAGED" 2>/dev/null || true
}

maybe_background(){
  if [[ "${HUNTEX_BG:-0}" == "1" ]]; then return 0; fi
  if [[ "$FORCE_FG" == "1" ]]; then return 0; fi

  if command -v systemd-run >/dev/null 2>&1; then
    mkdir -p /var/log >/dev/null 2>&1 || true
    safe_cwd

    try systemctl stop "${UNIT}.service" >/dev/null 2>&1 || true
    try systemctl reset-failed "${UNIT}.service" >/dev/null 2>&1 || true

    log "[*] Re-running in background via systemd-run. Logs: $LOG"

    systemd-run --unit="$UNIT" --collect --quiet \
      /usr/bin/env bash -c "
        set -Eeuo pipefail
        export HUNTEX_BG=1 FORCE_FG=1
        export IP='${IP}' PORT='${PORT}' USER='${USER}' NAME='${NAME}' PASS='${PASS}' WIPE_KEYS='${WIPE_KEYS}'
        cd /root || true
        /usr/bin/env bash '${STAGED}' >>'${LOG}' 2>&1
      " || warn "systemd-run failed, continuing in foreground..."

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
  # Do NOT touch other keys or the directory itself
}

generate_key(){
  ensure_ssh_dir
  rm -f "$KEY" "$PUB" 2>/dev/null || true
  log "[*] Generating fresh key for NAME=${NAME}"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null 2>&1 \
    || die "ssh-keygen failed"
  chmod 600 "$KEY" || true
  chmod 644 "$PUB" || true
  [[ -s "$KEY" ]] || die "Key not created: $KEY"
  [[ -s "$PUB" ]] || die "Pubkey not created: $PUB"
}

push_key(){
  [[ -n "$PASS" ]] || die "PASS is empty. Provide PASS=..."
  ensure_ssh_dir

  # ssh-copy-id uses mktemp under ~/.ssh on some distros -> force TMPDIR
  export TMPDIR="/tmp"

  log "[*] Sending key to remote via ssh-copy-id..."
  sshpass -p "$PASS" ssh-copy-id \
    -p "$PORT" \
    -i "$PUB" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$KNOWN" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${USER}@${IP}" >/dev/null 2>&1 \
    || die "ssh-copy-id failed"
}

test_key(){
  ensure_ssh_dir
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
  safe_cwd
  stage_self
  maybe_background

  log "==== HUNTEX KEY SETUP (${NAME}) ===="
  log "[i] IP=${IP} PORT=${PORT} USER=${USER}"
  log "[i] KEY=${KEY}"

  install_tools
  ensure_ssh_dir

  if [[ "$WIPE_KEYS" == "1" ]]; then
    wipe_name_only
    ensure_ssh_dir
  fi

  generate_key
  push_key
  test_key

  log "[+] DONE"
  log "[+] KEY PATH: $KEY"
}

main
