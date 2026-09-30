# Local Dev Infrastructure

Traefik reverse proxy + MySQL + phpMyAdmin + Mailpit + Dozzle for local WordPress/WooCommerce and other Docker-based projects.

## Quick Start

```bash
# After reboot — start infra first
cd ~/WebApps/env-manage/_infra && sudo docker compose up -d

# Then start any site
cd ~/WebApps/is-sklep.test && sudo docker compose up -d
```

## Paths

Sites live in `~/WebApps/<domain>/`, this repo in `~/WebApps/env-manage/_infra`. Keep both under `/home`: on Omarchy only `/` is snapshotted by snapper, so site files and `mysql_data` under e.g. `/srv/http` would bloat system snapshots and get rolled back with them.

Site compose files mount shared files (PHP ini, Mailpit mu-plugin, mkcert CA) via **relative** paths — `${INFRA_DIR:-../env-manage/_infra}` — so they don't depend on `$HOME`, which `sudo` resets to `/root`. With a different layout, pass the path explicitly:

```bash
sudo INFRA_DIR=/srv/http/_infra docker compose up -d
```

## Docker access (sudo)

Omarchy deliberately keeps users out of the `docker` group (membership = passwordless root), so every `docker` command here runs with `sudo`. Opt-in alternative: *Setup → Security → Sudoless Docker* (reboot required); the compose files work the same either way.

Editing site files owned by `33:33` (www-data in containers, `http` on Arch) requires the `http` group once: `sudo usermod -aG http $USER` (re-login).

## Architecture

```
Traefik :80/:443 (HTTPS, auto-discovery via Docker labels)
  ├── WP sites    → compose.yml per site in ~/WebApps/*.test/
  ├── Laravel/etc → compose.override.yml with Traefik labels
  ├── phpMyAdmin  → phpmyadmin.test
  ├── Mailpit     → mail.test (SMTP catch-all + web UI)
  └── Dozzle      → dozzle.test (Docker log viewer + container metrics)

MySQL 8.4  → shared by all WP sites via "db" Docker network
Mailpit    → catches all outgoing WP mail via mu-plugin on "proxy" network
Dozzle     → real-time log streaming for all Docker containers via "proxy" network
```

## Services

| Service | Access | Notes |
|---------|--------|-------|
| Traefik dashboard | http://127.0.0.1:8080 | loopback only |
| phpMyAdmin | https://phpmyadmin.test | |
| Mailpit | https://mail.test | SMTP on port 1025, web UI for caught emails |
| Dozzle | https://dozzle.test | Docker log viewer, container metrics |
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
cp *.pem ~/WebApps/env-manage/_infra/traefik/certs/
# rename to _wildcard.test.pem / _wildcard.test-key.pem
cd ~/WebApps/env-manage/_infra && sudo docker compose restart traefik
```

WP containers trust the same CA via `traefik/certs/rootCA.pem` (mounted by the site template). Copy it once per machine — the **public** cert only, never `rootCA-key.pem`:

```bash
cp "$(mkcert -CAROOT)/rootCA.pem" ~/WebApps/env-manage/_infra/traefik/certs/
```

Browser CA trust:
- Chromium: `mkcert -install` (auto)
- Zen/Firefox: `certutil -A -d "sql:<profile-path>" -t "C,," -n "mkcert" -i "$(mkcert -CAROOT)/rootCA.pem"`
- Find profiles: `find ~/.config/zen ~/.mozilla -name "cert9.db"`

## Adding a New WP Site

```bash
# 1. Copy template
cp ~/WebApps/env-manage/_infra/templates/wp-compose.template.yml ~/WebApps/mysite.test/compose.yml

# 2. Replace placeholders
sed -i 's/SITE_NAME/mysite/g; s/SITE_DOMAIN/mysite.test/g' ~/WebApps/mysite.test/compose.yml

# 3. Set permissions (all 3 steps required)
sudo chown -R 33:33 ~/WebApps/mysite.test
sudo chmod -R g+rwX ~/WebApps/mysite.test
sudo find ~/WebApps/mysite.test -type d -exec chmod g+s {} +

# 4. Edit wp-config.php
#    - DB_HOST → 'mysql'
#    - Add before "stop editing" line:
#        if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
#            $_SERVER['HTTPS'] = 'on';
#        }

# 5. Regenerate cert with new domain added
cd /tmp && mkcert mysite.test [plus all existing domains...]
cp *.pem ~/WebApps/env-manage/_infra/traefik/certs/
cd ~/WebApps/env-manage/_infra && sudo docker compose restart traefik

# 6. Start
cd ~/WebApps/mysite.test && sudo docker compose up -d
```

## WP-CLI

```bash
cd ~/WebApps/mysite.test
sudo docker compose run --rm wp-cli plugin list
sudo docker compose run --rm wp-cli plugin update --all
sudo docker compose run --rm wp-cli search-replace 'old-domain' 'new-domain'
sudo docker compose run --rm wp-cli cache flush
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
- ${INFRA_DIR:-../env-manage/_infra}/config/wp/mu-plugins/mailpit-smtp.php:/var/www/html/wp-content/mu-plugins/mailpit-smtp.php:ro
```

Restart the site container. The mu-plugin auto-activates (no wp-admin action needed).

## Dozzle (Docker Logs)

Real-time log viewer for all running Docker containers.

- **Web UI**: https://dozzle.test — live log streaming, container metrics (CPU/mem/net)
- **Actions/Shell**: disabled by default. Toggle in `.env`:
  ```
  DOZZLE_ENABLE_ACTIONS=true   # restart/stop/start containers from UI
  DOZZLE_ENABLE_SHELL=true     # open terminal sessions from UI
  ```
  Then `sudo docker compose up -d dozzle` to apply.

## Updates

Image tags follow the major/minor line and pick up patches on every pull: `traefik:v3.7`, `mysql:8.4` (LTS), `phpmyadmin:5.2`, `axllent/mailpit:v1`, `amir20/dozzle:v11`. For a new major/minor, read the changelog, bump the tag in `compose.yml`, commit and push.

```bash
cd ~/WebApps/env-manage/_infra
git pull
sudo docker compose pull
sudo docker compose up -d
sudo docker image prune -f
```

- **MySQL**: don't jump LTS lines (8.4 → 9.x) without a full dump first — the data directory is upgraded in place and cannot be downgraded.
- **WP sites** use `wordpress:php8.4-apache` / `wordpress:cli-php8.4` (tracks the PHP line, not the WP version). WP core lives in the site directory and is updated by WordPress itself; the image only provides PHP + Apache. Update a site with `sudo docker compose pull && sudo docker compose up -d` in its directory.

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
