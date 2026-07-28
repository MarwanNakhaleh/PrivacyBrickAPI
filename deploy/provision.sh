#!/usr/bin/env bash
# PrivacyBrick full-stack provisioner for a FRESH DietPi (Debian bookworm, arm64/armhf).
#
# Installs and wires: Unbound, AdGuard Home, cloudflared (DoH), Tailscale,
# ntopng, NextDNS CLI — then installs the PrivacyBrick API via deploy/install.sh.
#
# Resulting DNS chain (default, "forward" mode):
#   LAN clients :53 -> AdGuard Home -> 127.0.0.1:5335 Unbound -> 127.0.0.1:5053 cloudflared (DoH)
#
# Usage:
#   sudo bash deploy/provision.sh              # forward mode (Unbound -> cloudflared DoH)
#   sudo bash deploy/provision.sh --recursive  # Unbound does full recursion itself
#                                              # (DNSSEC via trust anchor; cloudflared unused)
#
# Safe to re-run: every step is idempotent. Config files that already exist
# with different content are backed up as <file>.bak.<epoch> before overwrite.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Ports used by the stack ──────────────────────────────────────────────────
ADGUARD_DNS_PORT=53      # AdGuard Home DNS, for the LAN
ADGUARD_UI_PORT=3000     # AdGuard Home web UI
UNBOUND_PORT=5335        # Unbound, localhost only
CLOUDFLARED_PORT=5053    # cloudflared DoH proxy, localhost only
NEXTDNS_PORT=5054        # NextDNS CLI, localhost only (installed, NOT active in chain)
NTOPNG_PORT=3001         # ntopng web/REST UI
API_PORT=8787            # PrivacyBrick API

RECURSIVE=0
for arg in "$@"; do
  case "$arg" in
    --recursive) RECURSIVE=1 ;;
    -h|--help)
      sed -n '2,17p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg (supported: --recursive)" >&2
      exit 1
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root:  sudo bash deploy/provision.sh" >&2
  exit 1
fi

ARCH="$(dpkg --print-architecture)"       # arm64 / armhf / amd64
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"

stage() { echo; echo "════════════════════════════════════════════════════════"; echo "==> $*"; echo "════════════════════════════════════════════════════════"; }
note()  { echo "    -> $*"; }

BACKED_UP=()
# write_config <path> <<'EOF' ... — writes stdin to <path>; if the file already
# exists with different content it is backed up first (and we say so).
write_config() {
  local dest="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$dest" ] && ! cmp -s "$tmp" "$dest"; then
    local bak="${dest}.bak.$(date +%s)"
    cp -a "$dest" "$bak"
    BACKED_UP+=("$bak")
    note "Existing $dest differed — backed up to $bak"
  fi
  install -D -m 644 "$tmp" "$dest"
  rm -f "$tmp"
}

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 0/8: Preflight — base packages, detect environment"
# ─────────────────────────────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl wget ca-certificates gnupg apt-transport-https \
  dnsutils python3 python3-yaml
note "Architecture: ${ARCH}, Debian codename: ${CODENAME}"

DEFAULT_IFACE="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"
PI_IP="$(ip -4 addr show "$DEFAULT_IFACE" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
PI_IP="${PI_IP:-<pi-ip>}"
note "Default interface: ${DEFAULT_IFACE}, address: ${PI_IP}"

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 1/8: Free port 53 (systemd-resolved stub listener, if present)"
# ─────────────────────────────────────────────────────────────────────────────
if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1 \
   && systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  mkdir -p /etc/systemd/resolved.conf.d
  write_config /etc/systemd/resolved.conf.d/99-privacybrick.conf <<'EOF'
# Installed by PrivacyBrick provision.sh — frees port 53 for AdGuard Home.
[Resolve]
DNSStubListener=no
EOF
  systemctl restart systemd-resolved || true
  note "systemd-resolved DNSStubListener disabled (port 53 freed)."
else
  note "systemd-resolved not active — nothing to do (typical on DietPi)."
fi

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 2/8: Unbound (apt) on 127.0.0.1:${UNBOUND_PORT}"
# ─────────────────────────────────────────────────────────────────────────────
apt-get install -y -qq unbound

# unbound-control is used by the PrivacyBrick API — make sure its keys exist.
if [ ! -f /etc/unbound/unbound_control.key ]; then
  unbound-control-setup -d /etc/unbound
  note "unbound-control keys generated (unbound-control-setup)."
else
  note "unbound-control keys already present."
fi

if [ "$RECURSIVE" -eq 1 ]; then
  note "--recursive: Unbound will do full recursion itself (cloudflared will be unused)."
  write_config /etc/unbound/unbound.conf.d/privacybrick.conf <<EOF
# Installed by PrivacyBrick provision.sh (--recursive mode).
# Unbound performs full recursion from the root servers, validating DNSSEC
# via the auto-managed trust anchor (Debian ships
# unbound.conf.d/root-auto-trust-anchor-file.conf pointing at
# /var/lib/unbound/root.key). No forward zone: cloudflared is NOT used.
server:
    interface: 127.0.0.1
    port: ${UNBOUND_PORT}
    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow

    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    qname-minimisation: yes
    prefetch: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400
    edns-buffer-size: 1232

remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
EOF
else
  write_config /etc/unbound/unbound.conf.d/privacybrick.conf <<EOF
# Installed by PrivacyBrick provision.sh (forward mode).
# Unbound forwards everything to the local cloudflared DoH proxy on
# 127.0.0.1:${CLOUDFLARED_PORT}, adding a local cache in between.
# Re-run provision.sh with --recursive for full recursion instead.
server:
    interface: 127.0.0.1
    port: ${UNBOUND_PORT}
    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow

    # Required so Unbound may forward to a resolver on localhost:
    do-not-query-localhost: no

    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    qname-minimisation: yes
    prefetch: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400
    edns-buffer-size: 1232

remote-control:
    control-enable: yes
    control-interface: 127.0.0.1

forward-zone:
    name: "."
    forward-addr: 127.0.0.1@${CLOUDFLARED_PORT}
EOF
fi

systemctl enable unbound >/dev/null 2>&1 || true
systemctl restart unbound
note "Unbound running on 127.0.0.1:${UNBOUND_PORT}."

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 3/8: cloudflared DoH proxy (Cloudflare apt repo) on 127.0.0.1:${CLOUDFLARED_PORT}"
# ─────────────────────────────────────────────────────────────────────────────
# Official repo per https://pkg.cloudflare.com/
if [ ! -f /usr/share/keyrings/cloudflare-main.gpg ]; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
fi
write_config /etc/apt/sources.list.d/cloudflared.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${CODENAME} main
EOF
apt-get update -qq
apt-get install -y -qq cloudflared

write_config /etc/default/cloudflared <<EOF
# Installed by PrivacyBrick provision.sh — options for the cloudflared
# DNS-over-HTTPS proxy (consumed by cloudflared.service).
CLOUDFLARED_OPTS=--address 127.0.0.1 --port ${CLOUDFLARED_PORT} --upstream https://cloudflare-dns.com/dns-query --upstream https://dns.quad9.net/dns-query
EOF

write_config /etc/systemd/system/cloudflared.service <<'EOF'
# Installed by PrivacyBrick provision.sh — runs cloudflared in proxy-dns
# (DNS-over-HTTPS) mode. The unit name "cloudflared" matches
# PRIVACYBRICK_DOH_SERVICE_UNIT in /etc/privacybrick/.env.
[Unit]
Description=cloudflared DNS-over-HTTPS proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/cloudflared
ExecStart=/usr/bin/cloudflared --no-autoupdate proxy-dns $CLOUDFLARED_OPTS
Restart=on-failure
RestartSec=5
DynamicUser=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared
systemctl restart cloudflared
if [ "$RECURSIVE" -eq 1 ]; then
  note "cloudflared installed and running on 127.0.0.1:${CLOUDFLARED_PORT}, but UNUSED in --recursive mode."
else
  note "cloudflared DoH proxy running on 127.0.0.1:${CLOUDFLARED_PORT} (Cloudflare + Quad9 upstreams)."
fi

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 4/8: AdGuard Home (official installer) — DNS :${ADGUARD_DNS_PORT}, UI :${ADGUARD_UI_PORT}"
# ─────────────────────────────────────────────────────────────────────────────
AGH_DIR=/opt/AdGuardHome
AGH_YAML="${AGH_DIR}/AdGuardHome.yaml"

if [ -x "${AGH_DIR}/AdGuardHome" ]; then
  note "AdGuard Home already installed at ${AGH_DIR} — skipping installer."
else
  # Official script per https://github.com/AdguardTeam/AdGuardHome
  curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
fi
systemctl enable AdGuardHome >/dev/null 2>&1 || true
systemctl start AdGuardHome || true

# AdGuard writes AdGuardHome.yaml only after its first-run wizard has been
# completed (web UI on :3000). Once that file exists — e.g. on a re-run of
# this script after the wizard — wire it into the chain: DNS on port 53 for
# the LAN, upstream = local Unbound.
if [ -f "$AGH_YAML" ]; then
  systemctl stop AdGuardHome || true
  BAK="${AGH_YAML}.bak.$(date +%s)"
  cp -a "$AGH_YAML" "$BAK"
  BACKED_UP+=("$BAK")
  note "Backed up existing AdGuard config to $BAK"
  python3 - "$AGH_YAML" "$ADGUARD_DNS_PORT" "$ADGUARD_UI_PORT" "$UNBOUND_PORT" <<'PYEOF'
import sys, yaml
path, dns_port, ui_port, unbound_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
cfg.setdefault("http", {})["address"] = "0.0.0.0:%d" % ui_port
dns = cfg.setdefault("dns", {})
dns["bind_hosts"] = ["0.0.0.0"]
dns["port"] = dns_port
dns["upstream_dns"] = ["127.0.0.1:%d" % unbound_port]
dns["bootstrap_dns"] = ["9.9.9.9", "1.1.1.1"]
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print("    -> Patched %s: DNS 0.0.0.0:%d, UI :%d, upstream 127.0.0.1:%d"
      % (path, dns_port, ui_port, unbound_port))
PYEOF
  systemctl start AdGuardHome
  ADGUARD_WIRED=1
else
  ADGUARD_WIRED=0
  note "No AdGuardHome.yaml yet — complete the first-run wizard at http://${PI_IP}:${ADGUARD_UI_PORT}"
  note "(choose web port ${ADGUARD_UI_PORT} and DNS port ${ADGUARD_DNS_PORT}), then RE-RUN this script"
  note "to wire AdGuard's upstream to Unbound automatically — or set the upstream to"
  note "127.0.0.1:${UNBOUND_PORT} yourself under Settings -> DNS settings."
fi

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 5/8: ntopng on :${NTOPNG_PORT} (packages.ntop.org if reachable, else Debian)"
# ─────────────────────────────────────────────────────────────────────────────
NTOP_SOURCE="Debian apt"
if ! command -v ntopng >/dev/null 2>&1; then
  # Prefer the official ntop repo (fresher builds). Repo setup deb per
  # https://packages.ntop.org/ (RaspberryPI flavour for arm, apt flavour else).
  case "$ARCH" in
    arm64|armhf) APT_NTOP_URL="https://packages.ntop.org/RaspberryPI/apt-ntop.deb" ;;
    *)           APT_NTOP_URL="https://packages.ntop.org/apt/${CODENAME}/all/apt-ntop.deb" ;;
  esac
  if curl -fsIL --max-time 15 "$APT_NTOP_URL" >/dev/null 2>&1; then
    TMPDEB="$(mktemp --suffix=.deb)"
    curl -fsSL --max-time 60 -o "$TMPDEB" "$APT_NTOP_URL"
    dpkg -i "$TMPDEB" || apt-get install -y -qq -f
    rm -f "$TMPDEB"
    apt-get update -qq
    if apt-get install -y -qq ntopng; then
      NTOP_SOURCE="packages.ntop.org"
    else
      note "packages.ntop.org install failed (dependency mismatch is common on Pi) — falling back to Debian apt."
      rm -f /etc/apt/sources.list.d/ntop*.list
      apt-get update -qq
      apt-get install -y -qq ntopng
    fi
  else
    note "packages.ntop.org not reachable — installing ntopng from Debian apt."
    apt-get install -y -qq ntopng
  fi
else
  note "ntopng already installed — skipping install."
fi

mkdir -p /etc/ntopng
write_config /etc/ntopng/ntopng.conf <<EOF
# Installed by PrivacyBrick provision.sh.
# Web/REST UI on ${NTOPNG_PORT} (AdGuard Home owns 3000), monitoring ${DEFAULT_IFACE}.
-w=${NTOPNG_PORT}
-i=${DEFAULT_IFACE}
EOF
# Debian's packaging wants this marker before it will start the service.
touch /etc/ntopng/ntopng.start 2>/dev/null || true

systemctl enable ntopng >/dev/null 2>&1 || true
systemctl restart ntopng || note "WARNING: ntopng failed to start — check 'journalctl -u ntopng'."
note "ntopng (${NTOP_SOURCE}) on http://${PI_IP}:${NTOPNG_PORT}, monitoring ${DEFAULT_IFACE}."

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 6/8: NextDNS CLI on 127.0.0.1:${NEXTDNS_PORT} (installed, NOT activated)"
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v nextdns >/dev/null 2>&1; then
  # Official installer per https://nextdns.io/install (github.com/nextdns/nextdns).
  # RUN_COMMAND makes it non-interactive; on Debian it adds repo.nextdns.io.
  RUN_COMMAND=install sh -c "$(curl -sL https://nextdns.io/install)" </dev/null \
    || note "WARNING: NextDNS installer failed — install manually later with: sh -c \"\$(curl -sL https://nextdns.io/install)\""
fi

if command -v nextdns >/dev/null 2>&1; then
  # NextDNS is an ALTERNATIVE cloud-filtering upstream. It listens on
  # 127.0.0.1:${NEXTDNS_PORT} but is deliberately NOT part of the DNS chain and is
  # NOT "activated" (it never touches /etc/resolv.conf or system DNS).
  # To route through NextDNS instead of the Unbound chain:
  #   1. nextdns config set -profile <your-profile-id>  && nextdns restart
  #   2. In AdGuard Home -> Settings -> DNS settings, replace upstream
  #      127.0.0.1:${UNBOUND_PORT} with 127.0.0.1:${NEXTDNS_PORT}.
  nextdns config set -listen "127.0.0.1:${NEXTDNS_PORT}" >/dev/null
  nextdns restart >/dev/null 2>&1 || nextdns start >/dev/null 2>&1 || true
  note "NextDNS CLI listening on 127.0.0.1:${NEXTDNS_PORT} — standing by, not in the chain."
  note "(Switch AdGuard's upstream to 127.0.0.1:${NEXTDNS_PORT} to use it; see comments in this script.)"
fi

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 7/8: Tailscale (official apt repo)"
# ─────────────────────────────────────────────────────────────────────────────
# Official repo per https://pkgs.tailscale.com/stable/ (bookworm).
if [ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]; then
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
fi
if [ ! -f /etc/apt/sources.list.d/tailscale.list ]; then
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list" \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
fi
apt-get update -qq
apt-get install -y -qq tailscale
systemctl enable --now tailscaled

TAILSCALE_PENDING=0
if tailscale status >/dev/null 2>&1; then
  note "Tailscale already up: $(tailscale ip -4 2>/dev/null | head -1)"
else
  note "Running 'tailscale up' (30s window) — watch for the auth URL below:"
  set +e
  timeout 30 tailscale up 2>&1 | sed 's/^/    | /'
  set -e
  if tailscale status >/dev/null 2>&1; then
    note "Tailscale is up: $(tailscale ip -4 2>/dev/null | head -1)"
  else
    TAILSCALE_PENDING=1
    note "Not authenticated yet — that's fine. Visit the URL above, or just run"
    note "'sudo tailscale up' again later; nothing else here depends on it."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
stage "Stage 8/8: PrivacyBrick API (deploy/install.sh)"
# ─────────────────────────────────────────────────────────────────────────────
bash "${REPO_DIR}/deploy/install.sh"

# ─────────────────────────────────────────────────────────────────────────────
stage "Summary"
# ─────────────────────────────────────────────────────────────────────────────
if [ "$RECURSIVE" -eq 1 ]; then
  CHAIN="LAN -> AdGuard Home :${ADGUARD_DNS_PORT} -> Unbound 127.0.0.1:${UNBOUND_PORT} (full recursion, DNSSEC; cloudflared installed but unused)"
else
  CHAIN="LAN -> AdGuard Home :${ADGUARD_DNS_PORT} -> Unbound 127.0.0.1:${UNBOUND_PORT} -> cloudflared DoH 127.0.0.1:${CLOUDFLARED_PORT} (Cloudflare/Quad9)"
fi
cat <<EOF

  DNS chain:   ${CHAIN}

  Running services and ports:
    AdGuard Home     DNS :${ADGUARD_DNS_PORT} (LAN)      web UI http://${PI_IP}:${ADGUARD_UI_PORT}
    Unbound          127.0.0.1:${UNBOUND_PORT}
    cloudflared DoH  127.0.0.1:${CLOUDFLARED_PORT}$( [ "$RECURSIVE" -eq 1 ] && echo "  (unused in --recursive mode)" )
    NextDNS CLI      127.0.0.1:${NEXTDNS_PORT}  (standby — NOT in the chain)
    ntopng           http://${PI_IP}:${NTOPNG_PORT}
    Tailscale        $( [ "$TAILSCALE_PENDING" -eq 1 ] && echo "LOGIN PENDING — run: sudo tailscale up" || echo "up ($(tailscale ip -4 2>/dev/null | head -1))" )
    PrivacyBrick API http://${PI_IP}:${API_PORT}  (pairing code printed above)

  Still to do (manual):
EOF
if [ "$ADGUARD_WIRED" -eq 1 ]; then
  echo "    1. AdGuard Home is wired to Unbound. Log in at http://${PI_IP}:${ADGUARD_UI_PORT} and put"
  echo "       your admin credentials into /etc/privacybrick/.env"
  echo "       (PRIVACYBRICK_ADGUARD_USERNAME / _PASSWORD), then:"
  echo "       sudo systemctl restart privacybrick-api"
else
  echo "    1. Finish AdGuard Home's first-run wizard: http://${PI_IP}:${ADGUARD_UI_PORT}"
  echo "       (web port ${ADGUARD_UI_PORT}, DNS port ${ADGUARD_DNS_PORT}). Then RE-RUN this script to point its"
  echo "       upstream at Unbound (127.0.0.1:${UNBOUND_PORT}) — or set that upstream in the UI."
  echo "       Afterwards, add the admin credentials you chose to /etc/privacybrick/.env"
  echo "       (PRIVACYBRICK_ADGUARD_USERNAME / _PASSWORD) and:"
  echo "       sudo systemctl restart privacybrick-api"
fi
if [ "$TAILSCALE_PENDING" -eq 1 ]; then
  echo "    2. Authenticate Tailscale:  sudo tailscale up"
fi
echo "    3. Point your router's DHCP DNS server at this Pi: ${PI_IP}"
echo "       (so every LAN device resolves through AdGuard Home)."
echo "    4. Optional: to use NextDNS as the upstream instead of the Unbound chain,"
echo "       set a profile (nextdns config set -profile <id>; nextdns restart) and"
echo "       change AdGuard's upstream to 127.0.0.1:${NEXTDNS_PORT} in its DNS settings."
if [ "${#BACKED_UP[@]}" -gt 0 ]; then
  echo
  echo "  Config backups made this run:"
  for b in "${BACKED_UP[@]}"; do echo "    ${b}"; done
fi
echo
echo "==> Provisioning complete. See deploy/PROVISIONING.md for verification steps."
