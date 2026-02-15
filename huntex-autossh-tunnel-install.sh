#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================
# HUNTEX Turbo AutoSSH Tunnel (FINAL)
# - Iran server runs autossh client
# - Connects to OUTSIDE HPN-SSH: IP:PORT (default 2222)
# - Opens local listener on IRAN: LHOST:LPORT (default 0.0.0.0:443)
# - Forwards to service on OUTSIDE: RHOST:RPORT (default 127.0.0.1:443)
# - Uses key: /root/.ssh/id_ed25519_iran-$(hostname -s)
# - NO prompt, FAIL-FAST, auto reconnect
# - systemd service + env file + CLI huntex-set-ip
# ==========================================

SERVICE="${SERVICE:-huntex-autossh-tunnel}"

# OUTSIDE (HPN-SSH server)
IP="${IP:-46.226.162.4}"
PORT="${PORT:-2222}"
USER="${USER:-root}"

# LOCAL listener on IRAN
LHOST="${LHOST:-0.0.0.0}"
LPORT="${LPORT:-443}"

# TARGET on OUTSIDE (service)
RHOST="${RHOST:-127.0.0.1}"
RPORT="${RPORT:-443}"

# Key naming: iran-[hostname]
HNAME="$(hostname -s 2>/dev/null || hostname || echo unknown)"
NAME="${NAME:-iran-${HNAME}}"
KEY="${KEY:-/root/.ssh/id_ed25519_${NAME}}"

SSH_DIR="/root/.ssh"
KNOWN="${SSH_DIR}/known_hosts_${SERVICE}"

ENV_FILE="/etc/default/${SERVICE}"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
SETIP_BIN="/usr/local/bin/huntex-set-ip"
LOGFILE="/var/log/${SERVICE}.log"

die(){ echo "❌ $*" >&2; exit 1; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*" >&2; }
log(){ echo "[$(date +'%F %T')] $*"; }

need_root(){ [[ "${EUID:-0}" -eq 0 ]] || die "Run as root (sudo)."; }

install_pkgs(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y autossh openssh-client sshpass ca-certificates coreutils >/dev/null 2>&1 || true
}

ensure_prereqs(){
  command -v autossh >/dev/null 2>&1 || die "autossh not found (apt install failed?)"
  command -v ssh >/dev/null 2>&1 || die "ssh not found (openssh-client missing?)"
  command -v ssh-keyscan >/dev/null 2>&1 || die "ssh-keyscan missing (openssh-client broken?)"
  command -v timeout >/dev/null 2>&1 || die "timeout missing (coreutils missing?)"
  command -v systemctl >/dev/null 2>&1 || die "systemd required (systemctl not found)"
  command -v ss >/dev/null 2>&1 || warn "ss not found (install iproute2) — service will still try."
}

ensure_key(){
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR" || true
  [[ -f "$KEY" ]] || die "SSH key not found: $KEY (run your key-setup first on IRAN so this key exists + is authorized on OUTSIDE)"
  chmod 600 "$KEY" || true
}

write_env(){
  cat >"$ENV_FILE" <<EOF
# HUNTEX AutoSSH env for ${SERVICE}
IP=${IP}
PORT=${PORT}
USER=${USER}
LHOST=${LHOST}
LPORT=${LPORT}
RHOST=${RHOST}
RPORT=${RPORT}
NAME=${NAME}
KEY=${KEY}
KNOWN=${KNOWN}
LOGFILE=${LOGFILE}
EOF
  chmod 600 "$ENV_FILE" || true
  ok "Wrote env -> $ENV_FILE"
}

write_setip(){
  cat >"$SETIP_BIN" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE="${SERVICE}"
ENV_FILE="${ENV_FILE}"

NEW_IP="\${1:-}"
if [[ -z "\$NEW_IP" ]]; then
  echo "Usage: huntex-set-ip NEW_IP"
  exit 1
fi

[[ -f "\$ENV_FILE" ]] || { echo "❌ Env file not found: \$ENV_FILE"; exit 2; }

if ! [[ "\$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}\$ ]]; then
  echo "❌ Invalid IP format: \$NEW_IP"
  exit 3
fi

echo "→ Updating IP to: \$NEW_IP"
if grep -q '^IP=' "\$ENV_FILE"; then
  sed -i "s/^IP=.*/IP=\${NEW_IP}/" "\$ENV_FILE"
else
  echo "IP=\${NEW_IP}" >> "\$ENV_FILE"
fi

echo "→ Restarting \${SERVICE}.service ..."
systemctl daemon-reload
systemctl restart "\${SERVICE}.service"
sleep 1

echo
systemctl --no-pager --full status "\${SERVICE}.service" | sed -n '1,20p' || true

LPORT="\$(grep -E '^LPORT=' "\$ENV_FILE" | head -n1 | cut -d= -f2 || true)"
if [[ -n "\${LPORT:-}" ]]; then
  echo
  ss -lntH "sport = :\${LPORT}" >/dev/null 2>&1 \
    && echo "✅ Tunnel is listening on \${LPORT}" \
    || (echo "❌ Tunnel not listening on \${LPORT}" && journalctl -u "\${SERVICE}.service" -n 80 --no-pager && exit 4)
fi
EOF
  chmod +x "$SETIP_BIN" || true
  ok "Installed CLI -> $SETIP_BIN  (use: huntex-set-ip x.x.x.x)"
}

write_unit(){
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=HUNTEX Turbo AutoSSH Tunnel (${LHOST}:${LPORT} -> ${RHOST}:${RPORT} via ${USER}@${IP}:${PORT})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Type=simple
User=root
EnvironmentFile=${ENV_FILE}

# autossh knobs (aggressive reconnect)
Environment=AUTOSSH_GATETIME=0
Environment=AUTOSSH_POLL=10
Environment=AUTOSSH_FIRST_POLL=5
Environment=AUTOSSH_LOGLEVEL=0

# Prepare log + ssh dir
ExecStartPre=/bin/bash -lc 'mkdir -p /root/.ssh; chmod 700 /root/.ssh; : > "\${LOGFILE}"; chmod 600 "\${LOGFILE}" || true'

# Fail if local port already in use
ExecStartPre=/bin/bash -lc 'command -v ss >/dev/null 2>&1 && ss -lntH "sport = :\${LPORT}" | grep -q . && { echo "Port \${LPORT} already in use" >> "\${LOGFILE}"; exit 1; } || exit 0'

# TCP reachability to outside SSH port
ExecStartPre=/bin/bash -lc 'timeout 5 bash -lc "cat </dev/null >/dev/tcp/\${IP}/\${PORT}" >/dev/null 2>&1 || { echo "TCP \${IP}:\${PORT} unreachable" >> "\${LOGFILE}"; exit 2; }'

# Refresh dedicated known_hosts (no prompt ever)
ExecStartPre=/bin/bash -lc 'rm -f "\${KNOWN}" || true; timeout 7 ssh-keyscan -p "\${PORT}" -H "\${IP}" > "\${KNOWN}" 2>/dev/null || true; chmod 600 "\${KNOWN}" || true'

# Fail-fast key-only auth test (no prompts)
ExecStartPre=/bin/bash -lc '[[ -f "\${KEY}" ]] || { echo "Missing KEY: \${KEY}" >> "\${LOGFILE}"; exit 3; }; chmod 600 "\${KEY}" || true'
ExecStartPre=/bin/bash -lc 'timeout 12 ssh -p "\${PORT}" -i "\${KEY}" "\${USER}@\${IP}" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="\${KNOWN}" \
  -o PreferredAuthentications=publickey \
  -o PubkeyAuthentication=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o IdentitiesOnly=yes \
  -o ExitOnForwardFailure=yes \
  -o ConnectTimeout=7 \
  -o ConnectionAttempts=1 \
  "echo AUTH_OK" >> "\${LOGFILE}" 2>&1 || { echo "Key auth failed" >> "\${LOGFILE}"; tail -n 80 "\${LOGFILE}" || true; exit 4; }'

# Main tunnel (Turbo)
ExecStart=/usr/bin/autossh -M 0 -N \
  -p \${PORT} \
  -i "\${KEY}" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="\${KNOWN}" \
  -o PreferredAuthentications=publickey \
  -o PubkeyAuthentication=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o IdentitiesOnly=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o TCPKeepAlive=yes \
  -o ConnectTimeout=7 \
  -o ConnectionAttempts=1 \
  -L \${LHOST}:\${LPORT}:\${RHOST}:\${RPORT} \
  \${USER}@\${IP} >> "\${LOGFILE}" 2>&1

Restart=always
RestartSec=2
TimeoutStartSec=30
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF
  ok "Wrote unit -> $UNIT_FILE"
}

enable_start(){
  systemctl daemon-reload
  systemctl enable --now "${SERVICE}.service"

  echo
  systemctl --no-pager --full status "${SERVICE}.service" | sed -n '1,22p' || true

  echo
  if command -v ss >/dev/null 2>&1 && ss -lntH "sport = :${LPORT}" | grep -q .; then
    ok "Tunnel is listening on ${LHOST}:${LPORT}"
  else
    warn "Tunnel may not be listening yet. Showing logs:"
    journalctl -u "${SERVICE}.service" -n 120 --no-pager || true
    tail -n 120 "${LOGFILE}" 2>/dev/null || true
    exit 5
  fi
}

main(){
  need_root
  install_pkgs
  ensure_prereqs
  ensure_key

  log "[*] Using NAME=${NAME}"
  log "[*] KEY=${KEY}"
  log "[*] OUTSIDE=${USER}@${IP}:${PORT}"
  log "[*] LOCAL LISTEN=${LHOST}:${LPORT} -> OUTSIDE TARGET=${RHOST}:${RPORT}"

  write_env
  write_setip
  write_unit
  enable_start

  echo
  ok "DONE"
  echo "Logs: ${LOGFILE}"
  echo "Change IP later: huntex-set-ip NEW_IP"
}

main "$@"
