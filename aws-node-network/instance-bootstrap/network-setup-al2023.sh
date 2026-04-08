#!/bin/bash
# Delegated node: local workspace for network/runtime state using a bounded slice of free disk.
# Intended for private subnets + SSM; VPC routing is configured in AWS (Client VPN, etc.).
set -euo pipefail

DELEGATED_ROOT="${DELEGATED_ROOT:-/opt/delegated-network}"
DISK_BUDGET_MB="${DISK_BUDGET_MB:-512}"

log() { echo "[delegated-network] $*"; }

if [[ $EUID -ne 0 ]]; then
  log "Re-run as root (EC2 user-data runs as root)."
  exit 1
fi

avail_mb="$(df -BM / 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}' || echo 0)"
log "Root volume free (approx): ${avail_mb} MB"

mkdir -p "${DELEGATED_ROOT}/"{bin,logs,state,cache,run}
chmod 750 "${DELEGATED_ROOT}"

cat >"${DELEGATED_ROOT}/bin/trim-cache.sh" <<EOF
#!/bin/bash
set -euo pipefail
ROOT="${DELEGATED_ROOT}"
find "\${ROOT}/cache" -type f -mtime +7 -delete 2>/dev/null || true
EOF
chmod 750 "${DELEGATED_ROOT}/bin/trim-cache.sh"

printf '0 3 * * 0 root %s/bin/trim-cache.sh >>%s/logs/trim.log 2>&1\n' "${DELEGATED_ROOT}" "${DELEGATED_ROOT}" >/etc/cron.d/delegated-network-trim
chmod 644 /etc/cron.d/delegated-network-trim

cat >/etc/sysctl.d/90-delegated-net.conf <<'EOS'
# Light defaults; adjust per workload
net.core.somaxconn = 1024
net.ipv4.tcp_fin_timeout = 30
EOS
sysctl --system >/dev/null 2>&1 || true

systemctl enable amazon-ssm-agent >/dev/null 2>&1 || true
systemctl start amazon-ssm-agent >/dev/null 2>&1 || true

cat >"${DELEGATED_ROOT}/state/bootstrap.json" <<EOF
{"delegated_root":"${DELEGATED_ROOT}","disk_budget_mb":${DISK_BUDGET_MB},"root_fs_free_mb_approx":${avail_mb:-0}}
EOF

log "Workspace ready: ${DELEGATED_ROOT} (soft cache budget ~${DISK_BUDGET_MB} MB). Logs: ${DELEGATED_ROOT}/logs"
