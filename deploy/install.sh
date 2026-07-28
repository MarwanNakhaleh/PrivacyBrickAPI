#!/usr/bin/env bash
# PrivacyBrick API installer for DietPi / Raspberry Pi OS.
# Run as root on the Pi:  sudo bash deploy/install.sh
set -euo pipefail

INSTALL_DIR=/opt/privacybrick
STATE_DIR=/etc/privacybrick
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Installing PrivacyBrick API from ${REPO_DIR}"

apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip

mkdir -p "${INSTALL_DIR}" "${STATE_DIR}"

if [ ! -d "${INSTALL_DIR}/venv" ]; then
  python3 -m venv "${INSTALL_DIR}/venv"
fi
"${INSTALL_DIR}/venv/bin/pip" install --upgrade pip -q
"${INSTALL_DIR}/venv/bin/pip" install -q "${REPO_DIR}"

if [ ! -f "${STATE_DIR}/.env" ]; then
  cat > "${STATE_DIR}/.env" <<'EOF'
# PrivacyBrick API configuration — edit to match your setup.
PRIVACYBRICK_DEVICE_NAME=PrivacyBrick

# AdGuard Home admin API (set the credentials you chose in AdGuard's setup)
PRIVACYBRICK_ADGUARD_URL=http://127.0.0.1:3000
PRIVACYBRICK_ADGUARD_USERNAME=
PRIVACYBRICK_ADGUARD_PASSWORD=

# ntopng REST API
PRIVACYBRICK_NTOPNG_URL=http://127.0.0.1:3001
PRIVACYBRICK_NTOPNG_TOKEN=

# systemd unit providing DNS-over-HTTPS (cloudflared, https-dns-proxy, or blank)
PRIVACYBRICK_DOH_SERVICE_UNIT=cloudflared
EOF
  chmod 600 "${STATE_DIR}/.env"
  echo "==> Wrote default config to ${STATE_DIR}/.env — edit it to add AdGuard credentials."
fi

install -m 644 "${REPO_DIR}/deploy/privacybrick-api.service" /etc/systemd/system/privacybrick-api.service
ln -sf "${INSTALL_DIR}/venv/bin/privacybrick-pair" /usr/local/bin/privacybrick-pair
install -m 755 "${REPO_DIR}/deploy/privacybrick-logs" /usr/local/bin/privacybrick-logs

systemctl daemon-reload
systemctl enable privacybrick-api
# restart (not `enable --now`): an already-running service must be bounced
# to load the code this script just installed.
systemctl restart privacybrick-api

echo
echo "==> PrivacyBrick API is running on port 8787."
echo "==> To pair a phone, run:  privacybrick-pair"
echo "==> To watch live logs, run:  privacybrick-logs   (or privacybrick-logs all)"
echo
"${INSTALL_DIR}/venv/bin/privacybrick-pair"
