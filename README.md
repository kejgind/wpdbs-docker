# Local Dev Infrastructure

Traefik reverse proxy + MySQL + phpMyAdmin + Mailpit for local WordPress/WooCommerce and other Docker-based projects.

## Quick Start

```bash
# After reboot — start infra first
cd /srv/http/_infra && docker compose up -d

# Then start any site
cd /srv/http/is-sklep.test && docker compose up -d
```

## Architecture

```
Traefik :80/:443 (HTTPS, auto-discovery via Docker labels)
  ├── WP sites    → compose.yml per site in /srv/http/*.test/
  ├── Laravel/etc → compose.override.yml with Traefik labels
  ├── phpMyAdmin  → phpmyadmin.test
  └── Mailpit     → mail.test (SMTP catch-all + web UI)

MySQL 8.4  → shared by all WP sites via "db" Docker network
Mailpit    → catches all outgoing WP mail via mu-plugin on "proxy" network
```

## Services

| Service | Access | Notes |
|---------|--------|-------|
| Traefik dashboard | http://127.0.0.1:8080 | loopback only |
| phpMyAdmin | https://phpmyadmin.test | |
| Mailpit | https://mail.test | SMTP on port 1025, web UI for caught emails |
| MySQL | 127.0.0.1:3306 | loopback only, for direct DB tools |

## DNS

All `*.test` domains resolve to `127.0.0.1`. No `/etc/hosts` entries needed.

```
┌──────────────┐
│ Applications │  (browser, curl, Docker containers)
└──────┬───────┘
       │
       ▼
┌──────────────────┐     *.test      ┌──────────────┐
│ systemd-resolved │ ───────────────▶│   dnsmasq    │
│   127.0.0.53     │                 │  127.0.0.1   │
└──────┬───────────┘                 │  172.17.0.1  │
       │ everything else             └──────────────┘
       ▼
┌──────────────┐
│   upstream   │  (router 192.168.1.1 via NM/DHCP)
└──────────────┘
```

### Config files

| File | Purpose |
|------|---------|
| `/etc/dnsmasq.conf` | `address=/test/127.0.0.1`, listens on 127.0.0.1 + 172.17.0.1 (Docker bridge) |
| `/etc/systemd/resolved.conf.d/local-dev.conf` | Routes `.test` queries to dnsmasq (`DNS=127.0.0.1`, `Domains=~test`) |
| `/etc/NetworkManager/conf.d/dns.conf` | `dns=systemd-resolved` — NM pushes DHCP DNS into resolved |
| `/etc/resolv.conf` | Symlink to resolved stub (`127.0.0.53`) — do not edit |

### Docker container DNS

WP containers use `dns: 172.17.0.1` (dnsmasq on Docker bridge). This lets containers resolve both `*.test` (local) and external domains. dnsmasq forwards non-`.test` queries to `192.168.1.1` (router).

### Troubleshooting

**`.test` domains not resolving (browser shows NS_ERROR_UNKNOWN_HOST):**

```bash
# Check dnsmasq is running
systemctl status dnsmasq

# If failed (common after reboot — race with Docker):
sudo systemctl restart dnsmasq

# Verify .test resolves
resolvectl query mail.test   # should return 127.0.0.1
```

**Internet not working:**

```bash
# Check resolved has upstream DNS
resolvectl status   # wlan0 should show DNS server (e.g. 192.168.1.1)

# If no DNS on wlan0, restart NM to re-push DHCP DNS
sudo systemctl restart NetworkManager
sudo systemctl restart systemd-resolved
```

**Both broken after reboot:**

```bash
# Full recovery — order matters
sudo systemctl restart dnsmasq          # bind-dynamic tolerates missing docker0
sudo systemctl restart systemd-resolved  # picks up .test routing
sudo systemctl restart NetworkManager    # re-pushes DHCP DNS into resolved
```

## HTTPS (mkcert)

Certs are in `traefik/certs/` (gitignored). To regenerate or add a domain:

```bash
cd /tmp && mkcert domain1.test domain2.test domain3.test ...
cp *.pem /srv/http/_infra/traefik/certs/
# rename to _wildcard.test.pem / _wildcard.test-key.pem
cd /srv/http/_infra && docker compose restart traefik
```

Browser CA trust:
- Chromium: `mkcert -install` (auto)
- Zen/Firefox: `certutil -A -d "sql:<profile-path>" -t "C,," -n "mkcert" -i "$(mkcert -CAROOT)/rootCA.pem"`
- Find profiles: `find ~/.config/zen ~/.mozilla -name "cert9.db"`

## Adding a New WP Site

```bash
# 1. Copy template
cp /srv/http/_infra/templates/wp-compose.template.yml /srv/http/mysite.test/compose.yml

# 2. Replace placeholders
sed -i 's/SITE_NAME/mysite/g; s/SITE_DOMAIN/mysite.test/g' /srv/http/mysite.test/compose.yml

# 3. Set permissions (all 3 steps required)
sudo chown -R 33:33 /srv/http/mysite.test
sudo chmod -R g+rwX /srv/http/mysite.test
sudo find /srv/http/mysite.test -type d -exec chmod g+s {} +

# 4. Edit wp-config.php
#    - DB_HOST → 'mysql'
#    - Add before "stop editing" line:
#        if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
#            $_SERVER['HTTPS'] = 'on';
#        }

# 5. Regenerate cert with new domain added
cd /tmp && mkcert mysite.test [plus all existing domains...]
cp *.pem /srv/http/_infra/traefik/certs/
cd /srv/http/_infra && docker compose restart traefik

# 6. Start
cd /srv/http/mysite.test && docker compose up -d
```

## WP-CLI

```bash
cd /srv/http/mysite.test
docker compose run --rm wp-cli plugin list
docker compose run --rm wp-cli plugin update --all
docker compose run --rm wp-cli search-replace 'old-domain' 'new-domain'
docker compose run --rm wp-cli cache flush
```

## Email (Mailpit)

All outgoing WordPress mail is caught by Mailpit — nothing is sent externally.

- **Web UI**: https://mail.test — view caught emails (HTML preview, attachments, headers)
- **SMTP**: `mailpit:1025` on the `proxy` network (no auth)
- **Storage**: ephemeral — emails are lost on container restart

### How it works

A mu-plugin at `config/wp/mu-plugins/mailpit-smtp.php` hooks `phpmailer_init` to route all `wp_mail()` calls to Mailpit. It's mounted read-only into WP containers via the compose template — new sites get it automatically.

### Adding to an existing site

Add this volume line to the wordpress service in the site's `compose.yml`:

```yaml
- /srv/http/_infra/config/wp/mu-plugins/mailpit-smtp.php:/var/www/html/wp-content/mu-plugins/mailpit-smtp.php:ro
```

Restart the site container. The mu-plugin auto-activates (no wp-admin action needed).

## Docker Networks

- `proxy` — Traefik ↔ containers (created by this compose)
- `db` — MySQL ↔ WP containers (created by this compose)

Both are referenced as `external: true` in site compose files.

## Non-WP Projects (Laravel, Symfony, etc.)

Add a `compose.override.yml` (gitignored) to route through Traefik:

```yaml
services:
  nginx:
    ports: !override []
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.test`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.services.myapp.loadbalancer.server.port=80"
    networks:
      - default
      - proxy

networks:
  proxy:
    external: true
```
