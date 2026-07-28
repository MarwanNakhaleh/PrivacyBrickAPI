# PrivacyBrickAPI

The local control-plane API for a **PrivacyBrick** — a Raspberry Pi (DietPi)
plugged into your router that runs Unbound, AdGuard Home, DNS-over-HTTPS,
Tailscale, ntopng, and the NextDNS CLI.

**It runs on the Pi itself. There is no cloud, no centralized server, and no
account.** The [PrivacyBrick iOS app](https://github.com/MarwanNakhaleh/PrivacyBrickUI-iOS)
finds the Pi on your WiFi automatically (Bonjour/mDNS), pairs once with a
6-digit code, and talks to this API directly. If Tailscale is up, the same API
is reachable securely from anywhere — still with no central server.

```
┌──────────┐   Bonjour discovery + HTTP (LAN)         ┌─────────────────────┐
│  iPhone  │ ───────────────────────────────────────▶ │  Raspberry Pi       │
│  (app)   │   or via Tailscale from anywhere         │  privacybrick-api   │
└──────────┘                                          │   ├─ unbound-control│
                                                      │   ├─ tailscale CLI  │
                                                      │   ├─ nextdns CLI    │
                                                      │   ├─ AdGuard REST   │
                                                      │   ├─ ntopng REST    │
                                                      │   └─ systemd/DietPi │
                                                      └─────────────────────┘
```

## Install (on the Pi)

```bash
git clone https://github.com/MarwanNakhaleh/PrivacyBrickAPI.git
cd PrivacyBrickAPI
sudo bash deploy/install.sh
```

The installer creates a venv in `/opt/privacybrick`, installs a systemd
service (`privacybrick-api`, port **8787**), writes a config template to
`/etc/privacybrick/.env`, and prints a pairing code.

Then edit `/etc/privacybrick/.env` to add your AdGuard Home admin credentials
(and ntopng token if you use one) and `sudo systemctl restart privacybrick-api`.

To pair another phone later: `privacybrick-pair`

## How each tool is controlled

| App-facing name  | Underlying tool | Mechanism |
|------------------|-----------------|-----------|
| Ad Blocking      | AdGuard Home    | local REST API (`/control/...`) |
| Private DNS      | Unbound         | `unbound-control` |
| Encrypted DNS    | DoH (cloudflared / https-dns-proxy) | systemd unit status |
| Remote Access    | Tailscale       | `tailscale` CLI (`--json`) |
| Cloud Filtering  | NextDNS         | `nextdns` CLI |
| Network Monitor  | ntopng          | local REST API (`/lua/rest/v2/...`) |
| Device           | DietPi / OS     | `systemctl`, `vcgencmd`, `free`, `df`, … |

All subprocess calls go through an **allowlist** (`privacybrick_api/runner.py`) —
the API can only run the specific binaries above, argv-style with no shell.

## API surface (all under `/api/v1`)

- `GET /ping` — unauthenticated identity check (used during discovery)
- `POST /pair` `{code, client_name}` → `{token}` — exchange pairing code for a bearer token
- `GET /overview` — one call for the app's home screen: per-service health + overall "protected"
- `GET|POST /adguard/{status,stats,querylog,protection}`
- `GET|POST /unbound/{status,stats,flush-cache,restart}`
- `GET|POST /doh/{status,restart}`
- `GET|POST /tailscale/{status,up,down}`
- `GET|POST /nextdns/{status,config,activate,deactivate,restart}`
- `GET /ntopng/{status,hosts,interface-stats}`
- `GET|POST /system/{info,reboot}`

Everything except `/ping` and `/pair` requires `Authorization: Bearer <token>`.
Interactive docs at `http://<pi>:8787/docs` while developing.

## Security model

- **Pairing**: single-use, 5-minute, 6-digit codes generated on the device
  (`privacybrick-pair`). Successful pairing issues a long-lived token stored
  in the phone's Keychain. Tokens live in `/etc/privacybrick/state.json` (0600).
- **No inbound cloud dependency**: the API binds to the LAN; remote access is
  only via your own tailnet.
- **Command allowlist**: no shell execution, fixed binary set, hard timeouts.
- Secrets for AdGuard/ntopng stay on the Pi; the phone only ever holds its
  bearer token.

## Development (any machine)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
PRIVACYBRICK_STATE_DIR=./tmp-state privacybrick-api   # http://localhost:8787/docs
pytest                                                 # smoke tests, no Pi needed
```

Service wrappers degrade gracefully when a tool isn't installed (reported as
`installed: false` in `/overview`), so the API runs fine on a laptop for UI
development.
