# Provisioning a PrivacyBrick from scratch

`deploy/provision.sh` turns a **fresh DietPi** (Debian bookworm, arm64/armhf)
into a complete PrivacyBrick. Run it as root from a clone of this repo:

```bash
sudo bash deploy/provision.sh              # default: Unbound forwards to cloudflared (DoH)
sudo bash deploy/provision.sh --recursive  # Unbound does full recursion itself
```

It is **idempotent** — re-running is safe and is actually part of the normal
flow (see [Post-install steps](#post-install-manual-steps)). Any existing
config file it would change is backed up first as `<file>.bak.<epoch>`.

## What it installs (latest, from official sources)

| Component | Source |
|---|---|
| Unbound | Debian apt |
| AdGuard Home | official installer (`raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh`) |
| cloudflared | Cloudflare apt repo (`pkg.cloudflare.com/cloudflared`) |
| Tailscale | Tailscale apt repo (`pkgs.tailscale.com/stable/debian`, bookworm) |
| ntopng | ntop apt repo (`packages.ntop.org`) if reachable, else Debian apt |
| NextDNS CLI | official installer (`nextdns.io/install`) |
| PrivacyBrick API | this repo, via `deploy/install.sh` (invoked at the end) |

It also disables `systemd-resolved`'s stub listener if present (to free
port 53) and runs `unbound-control-setup` (the API drives Unbound through
`unbound-control`).

## The DNS chain

Default (**forward** mode):

```
LAN clients / router
        │  port 53
        ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────────┐
│  AdGuard Home   │───▶│     Unbound      │───▶│  cloudflared (DoH)      │
│  0.0.0.0:53     │    │  127.0.0.1:5335  │    │  127.0.0.1:5053         │
│  (ad blocking)  │    │  (cache)         │    │  → cloudflare-dns.com   │
└─────────────────┘    └──────────────────┘    │  → dns.quad9.net        │
                                               └─────────────────────────┘

standby (not in chain):  NextDNS CLI on 127.0.0.1:5054
```

With **`--recursive`**: Unbound resolves directly from the root servers
(no forward zone) with DNSSEC validation via the auto-managed trust anchor
(`/var/lib/unbound/root.key`). cloudflared is still installed and running but
**unused**.

## Ports

| Port | Service | Bound to | Purpose |
|---|---|---|---|
| 53 | AdGuard Home | 0.0.0.0 | DNS for the LAN |
| 5335 | Unbound | 127.0.0.1 | caching resolver behind AdGuard |
| 5053 | cloudflared | 127.0.0.1 | DoH proxy (unused with `--recursive`) |
| 5054 | NextDNS CLI | 127.0.0.1 | alternative upstream, standby only |
| 3000 | AdGuard Home | 0.0.0.0 | web UI / REST API |
| 3001 | ntopng | 0.0.0.0 | web UI / REST API |
| 8787 | PrivacyBrick API | 0.0.0.0 | control-plane API for the iOS app |

## Flags

- `--recursive` — configure Unbound for full recursion (no forwarding,
  DNSSEC trust anchor) instead of forwarding to cloudflared. Switch modes any
  time by re-running the script with/without the flag.

## Post-install manual steps

1. **AdGuard Home first-run wizard** — open `http://<pi-ip>:3000`, choose web
   port **3000** and DNS port **53**, and create admin credentials. Then
   **re-run `provision.sh`**: it detects the now-existing
   `AdGuardHome.yaml` and patches the upstream to Unbound
   (`127.0.0.1:5335`) automatically. (Or set that upstream yourself under
   *Settings → DNS settings*.)
2. **API credentials** — put the AdGuard admin username/password into
   `/etc/privacybrick/.env` (`PRIVACYBRICK_ADGUARD_USERNAME` /
   `PRIVACYBRICK_ADGUARD_PASSWORD`, plus `PRIVACYBRICK_NTOPNG_TOKEN` if you
   create one), then `sudo systemctl restart privacybrick-api`.
3. **Tailscale login** — if the script printed an auth URL you didn't visit,
   run `sudo tailscale up` and follow the link.
4. **Router** — point your router's DHCP DNS at the Pi's LAN IP so every
   device on the network resolves through AdGuard Home.
5. *(Optional)* **NextDNS instead of the Unbound chain** —
   `sudo nextdns config set -profile <your-profile-id> && sudo nextdns restart`,
   then change AdGuard's upstream from `127.0.0.1:5335` to `127.0.0.1:5054`.
   The CLI is installed and listening but intentionally not "activated" (it
   never touches system DNS).

## Verifying each link of the chain

Run these **on the Pi** (`dnsutils` is installed by the script). Work from the
far end of the chain back toward the LAN:

```bash
# 1. cloudflared DoH proxy (skip in --recursive mode)
dig @127.0.0.1 -p 5053 example.com +short

# 2. Unbound (through cloudflared in forward mode, or full recursion)
dig @127.0.0.1 -p 5335 example.com +short

#    DNSSEC check: should return SERVFAIL (validation working)
dig @127.0.0.1 -p 5335 dnssec-failed.org +short

# 3. AdGuard Home on port 53 (only after its wizard + re-run of provision.sh)
dig @127.0.0.1 example.com +short
dig @<pi-ip>  example.com +short          # from another LAN machine

#    Ad blocking check: should return 0.0.0.0/NXDOMAIN once blocklists are on
dig @127.0.0.1 doubleclick.net +short

# 4. NextDNS standby listener
dig @127.0.0.1 -p 5054 example.com +short

# 5. Web UIs and API
curl -s http://127.0.0.1:3000/ -o /dev/null -w 'adguard ui: %{http_code}\n'
curl -s http://127.0.0.1:3001/ -o /dev/null -w 'ntopng ui:  %{http_code}\n'
curl -s http://127.0.0.1:8787/api/v1/ping

# 6. Services at a glance
systemctl --no-pager status unbound cloudflared AdGuardHome ntopng nextdns tailscaled privacybrick-api
sudo unbound-control status                 # the API uses this same channel
tailscale status
```

If a link fails, check its logs: `journalctl -u <unit> -e` (units: `unbound`,
`cloudflared`, `AdGuardHome`, `ntopng`, `nextdns`, `tailscaled`,
`privacybrick-api`).
