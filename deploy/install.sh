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

# systemd unit carrying encrypted DNS upstream. With the provisioned stack
# this is unbound itself (DNS-over-TLS forwarding); blank disables the card.
PRIVACYBRICK_DOH_SERVICE_UNIT=unbound
EOF
  chmod 600 "${STATE_DIR}/.env"
  echo "==> Wrote default config to ${STATE_DIR}/.env — edit it to add AdGuard credentials."
fi

# Record where the repo lives so the API's self-update endpoint can git-pull it.
# Appended outside the template block above (which only runs on first install),
# guarded so re-runs don't duplicate the line.
if ! grep -q '^PRIVACYBRICK_REPO_DIR=' "${STATE_DIR}/.env"; then
  {
    echo ""
    echo "# Where this git checkout lives (used by the in-app self-update)"
    echo "PRIVACYBRICK_REPO_DIR=${REPO_DIR}"
  } >> "${STATE_DIR}/.env"
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
# Only open a pairing window when someone is actually at a terminal. The
# detached self-update (deploy/self-update.sh) also runs this script, and it
# must NOT silently open a 5-minute window anyone on the LAN could pair with.
if [ -t 0 ]; then
  "${INSTALL_DIR}/venv/bin/privacybrick-pair"
fi
