#!/usr/bin/env bash
set -Eeuo pipefail

# ================================
# HUNTEX Turbo AutoSSH Tunnel v2
# - Installs autossh + service
# - Stores config in /etc/default/<service>
# - Installs CLI: huntex-set-ip <NEW_IP>
# - Restarts service safely and checks listening port
# ================================

# --------- REQUIRED INPUTS (edit or pass via env) ----------
SERVICE="${SERVICE:-huntex-autossh-tunnel}"

IP="${IP:-45.144.55.47}"
PORT="${PORT:-2222}"
USER="${USER:-root}"

# Local listener on Iran server
LHOST="${LHOST:-0.0.0.0}"
LPORT="${LPORT:-443}"

# Remote target (usually same as IP, but can differ)
RHOST="${RHOST:-45.144.55.47}"
RPORT="${RPORT:-443}"

# SSH key path (must exist and be authorized on remote)
KEY="${KEY:-/root/.ssh/id_ed25519_huntex}"

# Known_hosts file dedicated to this service (keeps things isolated)
KNOWN="/root/.ssh/known_hosts_${SERVICE}"

# Where we store the tun config (so huntex-set-ip can edit it)
ENV_FILE="/etc/default/${SERVICE}"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
SETIP_BIN="/usr/local/bin/huntex-set-ip"

# --------- Helpers ----------
die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "✅ $*"; }
warn(){ echo "⚠️  $*" >&2; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."
}

install_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y autossh openssh-client >/dev/null 2>&1 || true
}

ensure_key() {
  [[ -f "$KEY" ]] || die "SSH key not found: $KEY  (Run key-setup script first or set KEY=...)"
  chmod 600 "$KEY" || true
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
}

write_env() {
  cat >"$ENV_FILE" <<EOF
# HUNTEX tunnel env for ${SERVICE}
IP=${IP}
PORT=${PORT}
USER=${USER}
LHOST=${LHOST}
LPORT=${LPORT}
RHOST=${RHOST}
RPORT=${RPORT}
KEY=${KEY}
KNOWN=${KNOWN}
EOF
  chmod 600 "$ENV_FILE" || true
  ok "Wrote env -> $ENV_FILE"
}

write_setip() {
  cat >"$SETIP_BIN" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================
# huntex-set-ip NEW_IP
# - updates /etc/default/<service>
# - restarts tunnel service
# ==================================

SERVICE="${SERVICE:-huntex-autossh-tunnel}"
ENV_FILE="/etc/default/${SERVICE}"

NEW_IP="${1:-}"
if [[ -z "$NEW_IP" ]]; then
  echo "Usage: huntex-set-ip NEW_IP"
  exit 1
fi

[[ -f "$ENV_FILE" ]] || { echo "❌ Env file not found: $ENV_FILE"; exit 2; }

# Basic IP sanity (simple, not perfect)
if ! [[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "❌ Invalid IP format: $NEW_IP"
  exit 3
fi

echo "→ Updating IP to: $NEW_IP"

if grep -q '^IP=' "$ENV_FILE"; then
  sed -i "s/^IP=.*/IP=${NEW_IP}/" "$ENV_FILE"
else
  echo "IP=${NEW_IP}" >> "$ENV_FILE"
fi

echo "→ Restarting ${SERVICE}.service ..."
systemctl daemon-reload
systemctl restart "${SERVICE}.service"

sleep 1

echo
systemctl --no-pager --full status "${SERVICE}.service" | sed -n '1,18p'

# Try to detect LPORT from env to check listening
LPORT="$(grep -E '^LPORT=' "$ENV_FILE" | head -n1 | cut -d= -f2 || true)"
if [[ -n "$LPORT" ]]; then
  echo
  ss -lntp | grep -E "(:${LPORT})\b" >/dev/null 2>&1 \
    && echo "✅ Tunnel is listening on ${LPORT}" \
    || (echo "❌ Tunnel not listening on ${LPORT}" && journalctl -u "${SERVICE}.service" -n 40 --no-pager && exit 4)
fi
EOF

  chmod +x "$SETIP_BIN"
  ok "Installed CLI -> $SETIP_BIN  (use: huntex-set-ip x.x.x.x)"
}

write_unit() {
  # Service will load everything from ENV_FILE (including IP)
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=HUNTEX Turbo AutoSSH Tunnel (${LHOST}:${LPORT} -> ${RHOST}:${RPORT} via ${IP}:${PORT})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=root

EnvironmentFile=${ENV_FILE}

Environment="AUTOSSH_GATETIME=0"
Environment="AUTOSSH_POLL=10"
Environment="AUTOSSH_FIRST_POLL=5"
Environment="AUTOSSH_LOGLEVEL=0"

# Fail fast if local port is already bound (prevents restart spam)
ExecStartPre=/bin/bash -lc 'ss -lnt | awk "{print \$4}" | grep -qE "(^|:)'"${LPORT}"'\$" && { echo "Port '"${LPORT}"' already in use"; exit 1; } || exit 0'

ExecStart=/usr/bin/autossh -M 0 -N \\
  -p \${PORT} \\
  -i "\${KEY}" \\
  -o StrictHostKeyChecking=accept-new \\
  -o UserKnownHostsFile="\${KNOWN}" \\
  -o PreferredAuthentications=publickey \\
  -o PubkeyAuthentication=yes \\
  -o PasswordAuthentication=no \\
  -o KbdInteractiveAuthentication=no \\
  -o IdentitiesOnly=yes \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=20 \\
  -o ServerAliveCountMax=3 \\
  -o TCPKeepAlive=yes \\
  -o ConnectTimeout=10 \\
  -o ConnectionAttempts=3 \\
  -L \${LHOST}:\${LPORT}:\${RHOST}:\${RPORT} \\
  \${USER}@\${IP}

Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  ok "Wrote unit -> $UNIT_FILE"
}

enable_start() {
  systemctl daemon-reload
  systemctl enable --now "${SERVICE}.service"

  echo
  systemctl --no-pager --full status "${SERVICE}.service" | sed -n '1,22p'

  echo
  ss -lntp | grep -E "(:${LPORT})\b" && ok "Tunnel is listening on ${LPORT}" || warn "Tunnel not listening yet."
}

main() {
  need_root
  install_pkgs
  ensure_key
  write_env
  write_setip
  write_unit
  enable_start

  echo
  ok "Done."
  echo "Use: huntex-set-ip YOUR_NEW_IP"
}

main "$@"
