# Local Dev Infrastructure

Traefik reverse proxy + MySQL + phpMyAdmin + Mailpit + Dozzle for local WordPress/WooCommerce and other Docker-based projects.

This branch targets **Omarchy** and builds on what it already configures: `sudo` Docker, `/etc/docker/daemon.json` (container DNS `172.17.0.1`, fixed `bip`), systemd-resolved listening on the Docker bridge, and ufw + ufw-docker. `.test` domains are only for Docker apps; everything else (Astro, Laravel dev servers, …) runs on `localhost:<port>`.

## Quick Start

```bash
# After reboot — start infra first
cd ~/WebApps/env-manage/local_infra && sudo docker compose up -d

# Then start any site
cd ~/WebApps/is-sklep.test && sudo docker compose up -d
```

## Paths

Sites live in `~/WebApps/<domain>/`, this repo in `~/WebApps/env-manage/local_infra`. Keep both under `/home`: on Omarchy only `/` is snapshotted by snapper, so site files and `mysql_data` under e.g. `/srv/http` would bloat system snapshots and get rolled back with them.

Site compose files mount shared files (PHP ini, Mailpit mu-plugin, mkcert CA) via **relative** paths — `${INFRA_DIR:-../env-manage/local_infra}` — so they don't depend on `$HOME`, which `sudo` resets to `/root`. With a different layout, pass the path explicitly:

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

`*.test` names resolve through `/etc/hosts` — one line per domain, nothing else to configure. systemd-resolved (Omarchy default, `/etc/resolv.conf` → stub `127.0.0.53`) answers from `/etc/hosts` before routing a query anywhere, so it works the same with ProtonVPN or NetBird connected and doesn't touch LAN names (`*.local` goes through avahi/mDNS). Traefik can't help here: it only routes requests that already reached `127.0.0.1` by `Host` header.

Infra domains, once per machine:

```bash
echo '127.0.0.1 phpmyadmin.test mail.test dozzle.test' | sudo tee -a /etc/hosts
```

Each new site adds its own line (see [Adding a New WP Site](#adding-a-new-wp-site)). Non-Docker apps (Astro, Laravel via `artisan serve`, …) stay on `localhost:<port>` and need nothing.

### Docker container DNS

- A site reaches **its own** domain via `extra_hosts: SITE_DOMAIN:host-gateway` (in the template) → Traefik on the host. WP loopback requests (wp-cron, Site Health, Action Scheduler) depend on this.
- Every container queries `172.17.0.1` by default (Omarchy's `/etc/docker/daemon.json`), which is systemd-resolved on the Docker bridge (`/etc/systemd/resolved.conf.d/20-docker-dns.conf` from `omarchy-settings`, `DNSStubListenerExtra=172.17.0.1`; ufw allows it via the `allow-docker-dns` rules). Containers follow the host's DNS, VPN included — no `dns:` in site compose files.
- A `.test` name answered from the host's `/etc/hosts` means `127.0.0.1` — inside a container that's the container itself. A site calling **another** `.test` site needs that domain in its own `extra_hosts` too.

### Why not dnsmasq or `.localhost`

- **dnsmasq** (wildcard `*.test`) needs resolved routing config and must not bind `172.17.0.1:53`, which resolved already holds on Omarchy; forwarding non-`.test` queries to the router would also bypass VPN DNS. Not worth it for a handful of sites.
- **`.localhost`** resolves with zero config, but curl resolves `*.localhost` to loopback internally, ignoring `/etc/hosts` and `extra_hosts` — WP loopback requests from containers would hit the container instead of Traefik.

### Troubleshooting

```bash
getent hosts mysite.test     # 127.0.0.1 → name OK; empty → missing /etc/hosts line
resolvectl query mysite.test # same, through resolved (what browsers use)

# Name OK but the page fails → Traefik / cert side
sudo docker compose -f ~/WebApps/env-manage/local_infra/compose.yml ps traefik

# Inside a site container — should print the host-gateway IP, not 127.0.0.1
cd ~/WebApps/mysite.test && sudo docker compose exec wordpress getent hosts mysite.test
```

## Firewall (ufw)

Omarchy runs ufw (`default deny incoming`) with ufw-docker. ufw-docker lets **any private-range source** (`10/8`, `172.16/12`, `192.168/16` — your LAN, a café Wi-Fi) reach published container ports, so Traefik publishes `:80`/`:443` only on `127.0.0.1` (browser) and `172.17.0.1` (docker0, for site containers via `host-gateway`) — not `0.0.0.0`. MySQL and the Traefik dashboard stay on `127.0.0.1`.

Check that a site container reaches its own domain through Traefik (WP loopback: wp-cron, Site Health, Action Scheduler):

```bash
cd ~/WebApps/mysite.test && sudo docker compose exec wordpress curl -sI https://mysite.test | head -1   # HTTP/... 200/301/302
```

If it hangs or is refused, ufw is dropping container → host traffic on `:443` (only DNS is allowed by default). Mirror Omarchy's DNS rule for HTTPS:

```bash
sudo ufw allow in proto tcp from 172.16.0.0/12 to 172.17.0.1 port 443 comment 'allow-docker-traefik'
```

## HTTPS (mkcert)

One-time setup (`certutil` comes from `nss`, already installed on Omarchy):

```bash
sudo pacman -S mkcert
mkcert -install        # system trust store + Chromium (Omarchy default browser)
```

Certs are in `traefik/certs/` (gitignored). To regenerate or add a domain:

```bash
cd /tmp && mkcert domain1.test domain2.test domain3.test ...
cp *.pem ~/WebApps/env-manage/local_infra/traefik/certs/
# rename to _wildcard.test.pem / _wildcard.test-key.pem
cd ~/WebApps/env-manage/local_infra && sudo docker compose restart traefik
```

WP containers trust the same CA via `traefik/certs/rootCA.pem` (mounted by the site template). Copy it once per machine — the **public** cert only, never `rootCA-key.pem`:

```bash
cp "$(mkcert -CAROOT)/rootCA.pem" ~/WebApps/env-manage/local_infra/traefik/certs/
```

Browser CA trust:
- Chromium: `mkcert -install` (auto)
- Zen/Firefox: `certutil -A -d "sql:<profile-path>" -t "C,," -n "mkcert" -i "$(mkcert -CAROOT)/rootCA.pem"`
- Find profiles: `find ~/.config/zen ~/.mozilla -name "cert9.db"`

## Adding a New WP Site

```bash
# 1. Copy template
cp ~/WebApps/env-manage/local_infra/templates/wp-compose.template.yml ~/WebApps/mysite.test/compose.yml

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
cp *.pem ~/WebApps/env-manage/local_infra/traefik/certs/
cd ~/WebApps/env-manage/local_infra && sudo docker compose restart traefik

# 6. Resolve the domain on the host
echo '127.0.0.1 mysite.test' | sudo tee -a /etc/hosts

# 7. Start
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
- ${INFRA_DIR:-../env-manage/local_infra}/config/wp/mu-plugins/mailpit-smtp.php:/var/www/html/wp-content/mu-plugins/mailpit-smtp.php:ro
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
cd ~/WebApps/env-manage/local_infra
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
