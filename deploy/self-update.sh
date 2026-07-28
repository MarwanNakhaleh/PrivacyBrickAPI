#!/usr/bin/env bash
# PrivacyBrick self-updater. Launched DETACHED by the API (POST
# /api/v1/system/update) as a transient systemd unit:
#   systemd-run --unit=privacybrick-update --collect /bin/bash self-update.sh <repo_dir>
# Detached because install.sh restarts privacybrick-api, which would kill an
# updater running inside the API process.
set -euo pipefail

REPO_DIR="${1:?usage: self-update.sh <repo_dir>}"

git -C "${REPO_DIR}" pull --ff-only
exec bash "${REPO_DIR}/deploy/install.sh"
