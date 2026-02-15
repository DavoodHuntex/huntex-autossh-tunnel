#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# HUNTEX Key Setup (HPN SSH)
# - Works with both: curl | bash   AND   downloaded file
# - Creates a unique ED25519 key for this IR server (NAME)
# - Pushes pubkey to remote HPN SSH server (IP:PORT)
# - Optional detached run via systemd-run to survive SSH drop
#
# ENV:
#   IP, PORT, USER, NAME, PASS
#   WIPE_KEYS=0/1     (remove only this NAME artifacts)
#   FORCE_FG=0/1      (disable systemd-run)
# ============================================================

# -------- Inputs (env overrides) --------
IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
NAME="${NAME:-filestore-IR-01}"
PASS="${PASS:-}"
WIPE_KEYS="${WIPE_KEYS:-0}"
FORCE_FG="${FORCE_FG:-0}"

# -------- Paths --------
SSH_DIR="/root/.ssh"
KEY="${SSH_DIR}/id_ed25519_${NAME}"
PUB="${KEY}.pub"
KNOWN="${SSH_DIR}/known_hosts_${NAME}"

UNIT="huntex-key-setup-${NAME}"
LOG="/var/log/huntex-key-setup_${NAME}.log"
STAGED="/usr/local/bin/${UNIT}.sh"

# -------- Helpers --------
ts(){ date "+%F %T"; }
log(){ echo "[$(ts)] $*"; }
warn(){ echo "[$(ts)] [WARN] $*" >&2; }
die(){ echo "[$(ts)] [FATAL] $*" >&2; exit 1; }

need_root(){ [[ "${EUID:-0}" -eq 0 ]] || die "Run as root (sudo)."; }

# Avoid running from deleted cwd (you had rm -rf /root/.ssh while being inside it)
safe_cwd(){ cd / || true; cd /root || true; }

try(){ set +e; "$@"; local rc=$?; set -e; return $rc; }

ensure_dirs(){
  mkdir -p /var/log >/dev/null 2>&1 || true
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR" || true
}

install_tools(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y openssh-client sshpass >/dev/null 2>&1 || true
  command -v sshpass >/dev/null 2>&1 || die "sshpass install failed"
  command -v ssh-copy-id >/dev/null 2>&1 || die "ssh-copy-id missing (openssh-client failed?)"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen missing"
}

wipe_name_artifacts(){
  log "[!] WIPE_KEYS=1 -> wiping artifacts for this NAME only"
  rm -f "$KEY" "$PUB" "$KNOWN" 2>/dev/null || true
}

generate_key(){
  rm -f "$KEY" "$PUB" 2>/dev/null || true
  log "[*] Generating key: $KEY"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${NAME}@$(hostname)" >/dev/null 2>&1 \
    || die "ssh-keygen failed"
  chmod 600 "$KEY" || true
  chmod 644 "$PUB" || true
  [[ -s "$KEY" ]] || die "Key not created: $KEY"
  [[ -s "$PUB" ]] || die "Pubkey not created: $PUB"
}

push_key(){
  [[ -n "$PASS" ]] || die "PASS is empty. Provide PASS=... (no prompt)."
  log "[*] Pushing pubkey to ${USER}@${IP}:${PORT}"
  sshpass -p "$PASS" ssh-copy-id \
    -p "$PORT" \
    -i "$PUB" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$KNOWN" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${USER}@${IP}" >/dev/null 2>&1 \
    || die "ssh-copy-id failed (wrong PASS/IP/PORT or remote down)."
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
    || die "Key-only test failed (publickey not accepted)."
}

# -------- Stage self for curl|bash --------
stage_self(){
  ensure_dirs
  safe_cwd

  # If running from stdin (curl|bash), we must materialize script to disk.
  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "$src" || "$src" == "/dev/fd/"* || "$src" == "/proc/"* || ! -f "$src" ]]; then
    log "[*] Running from stdin -> staging to $STAGED"
    cat >"$STAGED"
    chmod 700 "$STAGED"
    exec /usr/bin/env bash "$STAGED"
  fi

  # If running from file, keep a copy at STAGED (for systemd-run reliability)
  cp -f "$src" "$STAGED" 2>/dev/null || true
  chmod 700 "$STAGED" 2>/dev/null || true
}

# -------- Background via systemd-run (safe) --------
maybe_background(){
  # already background?
  if [[ "${HUNTEX_BG:-0}" == "1" ]]; then return 0; fi
  # forced foreground?
  if [[ "$FORCE_FG" == "1" ]]; then
    warn "FORCE_FG=1 -> running in foreground."
    return 0
  fi

  if command -v systemd-run >/dev/null 2>&1; then
    ensure_dirs
    safe_cwd

    # stop old unit if exists
    try systemctl stop "${UNIT}.service" >/dev/null 2>&1 || true
    try systemctl reset-failed "${UNIT}.service" >/dev/null 2>&1 || true

    log "[*] Re-running in background via systemd-run. Logs: $LOG"

    # NOTE: This is the critical part: we run the staged script file, not $0.
    systemd-run --unit="$UNIT" --collect --quiet \
      /usr/bin/env bash -c "
        set -Eeuo pipefail
        export HUNTEX_BG=1
        export FORCE_FG=1
        export IP='${IP}' PORT='${PORT}' USER='${USER}' NAME='${NAME}' PASS='${PASS}' WIPE_KEYS='${WIPE_KEYS}'
        cd /root || true
        /usr/bin/env bash '${STAGED}' >>'${LOG}' 2>&1
      " || warn "systemd-run failed, continuing in foreground..."

    # if unit started, exit now
    if systemctl is-active --quiet "${UNIT}.service" 2>/dev/null; then
      echo "[+] Started. Follow logs:"
      echo "    tail -f ${LOG}"
      exit 0
    fi
  fi

  warn "systemd-run unavailable/failed -> running in foreground."
}

main(){
  need_root
  safe_cwd
  stage_self
  maybe_background

  # foreground work (or inside systemd-run)
  ensure_dirs

  log "==== HUNTEX KEY SETUP (${NAME}) ===="
  log "[i] IP=${IP} PORT=${PORT} USER=${USER}"
  log "[i] KEY=${KEY}"
  log "[i] KNOWN=${KNOWN}"
  log "[i] WIPE_KEYS=${WIPE_KEYS}"

  [[ -n "$IP" ]] || die "IP empty"
  [[ -n "$PORT" ]] || die "PORT empty"
  [[ -n "$USER" ]] || die "USER empty"
  [[ -n "$NAME" ]] || die "NAME empty"

  install_tools

  if [[ "$WIPE_KEYS" == "1" ]]; then
    wipe_name_artifacts
  fi

  generate_key
  push_key
  test_key

  log "[+] DONE"
  log "[+] KEY PATH: $KEY"
}

main
