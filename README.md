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

Nothing starts on its own: every service (infra and the site template) uses `restart: "no"`. On Omarchy Docker is socket-activated (`docker.socket`), so `unless-stopped` containers would come back on the first `docker` command after a reboot. Stop everything with `docker compose down` (or `stop`) in each directory.

## Paths

Sites live in `~/WebApps/<domain>/`, this repo in `~/WebApps/env-manage/local_infra`. Keep both under `/home`: on Omarchy only `/` is snapshotted by snapper, so site files and `mysql_data` under e.g. `/srv/http` would bloat system snapshots and get rolled back with them.

Site compose files mount shared files (PHP ini, Mailpit mu-plugin, mkcert CA) via **relative** paths — `${INFRA_DIR:-../env-manage/local_infra}` — so they don't depend on `$HOME`, which `sudo` resets to `/root`. With a different layout, pass the path explicitly:

```bash
sudo INFRA_DIR=/srv/http/_infra docker compose up -d
```

## Docker access (sudo)

Omarchy deliberately keeps users out of the `docker` group (membership = passwordless root), so every `docker` command here runs with `sudo`. Opt-in alternative: *Setup → Security → Sudoless Docker* (reboot required); the compose files work the same either way.

## Site file ownership (UID 1000)

Site files stay owned by you — no `chown 33:33`, no `http` group, no setgid. The template builds `local/wordpress:php8.4-apache-uid1000`: the official image with `www-data` renumbered to UID/GID 1000 (your host user, `id -u`), so Apache workers/PHP run as you inside the container, and wp-cli runs with `user: "1000:1000"`. WordPress sees PHP as the file owner and writes plugins/updates/uploads directly, and everything it writes is yours on the host. Apache's master process stays root only to bind port 80.

- **Don't** use `APACHE_RUN_USER=#1000` instead: the image has no passwd entry for 1000, Apache can't drop privileges (`AH02155`) and PHP keeps running as **root**.
- Trade-off: a container escape would land as your user rather than the unprivileged `http`. Acceptable for local dev — membership in the `docker` group (Sudoless Docker) is already root-equivalent.
- Sites under `~/WebApps` (not `/srv/http`) — see [Paths](#paths).
- Migrating a site that was `chown`ed to `33:33`: `sudo chown -R $USER: ~/WebApps/<site>` once.

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

Verified on Omarchy (ufw + ufw-docker, Docker 29): containers reach `172.17.0.1:80/443` through `host-gateway` with no extra rules, whether they share the `proxy` network with Traefik or not, and the LAN IP doesn't answer on `:443`. If a future ufw/Omarchy change breaks it (the check hangs or is refused), mirror Omarchy's DNS rule for HTTPS:

```bash
sudo ufw allow in proto tcp from 172.16.0.0/12 to 172.17.0.1 port 443 comment 'allow-docker-traefik'
```

## HTTPS (mkcert)

One-time setup (`certutil` comes from `nss`, already installed on Omarchy):

```bash
sudo pacman -S mkcert
mkcert -install        # system trust store + Chromium (Omarchy default browser)
```

**Before the first site starts**, `traefik/certs/rootCA.pem` must exist (see below). Docker creates a missing bind-mount source as an empty root-owned **directory**, which then blocks copying the real file there. Same for any absolute path in an old site `compose.yml` (`/srv/http/_infra/...`, `${HOME}/.local/share/mkcert/rootCA.pem`) — regenerate such files from the template instead of starting them.

Moving from another machine: either copy its CA (`rootCA.pem` + `rootCA-key.pem` from `mkcert -CAROOT` there into `mkcert -CAROOT` here, then `mkcert -install`) so existing certs stay valid, or start a fresh CA here and regenerate the Traefik cert. Check which CA signed the current cert:

```bash
openssl x509 -in traefik/certs/_wildcard.test.pem -noout -issuer -ext subjectAltName
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
- Zen/Firefox: `certutil -A -d "sql:<profile-path>" -t "C,," -n "mkcert" -i "$(mkcert -CAROOT)/rootCA.pem"` — required for Zen: `zen-browser-bin` bundles its own NSS (`/opt/zen-browser-bin/libnssckbi.so`), so it ignores the system trust store, and `mkcert -install` doesn't look in `~/.config/zen`. Once per profile; restart Zen afterwards.
- Find profiles: `find ~/.config/zen ~/.mozilla -name "cert9.db"`

## Adding a New WP Site

```bash
# 1. Copy template
cp ~/WebApps/env-manage/local_infra/templates/wp-compose.template.yml ~/WebApps/mysite.test/compose.yml

# 2. Replace placeholders
sed -i 's/SITE_NAME/mysite/g; s/SITE_DOMAIN/mysite.test/g' ~/WebApps/mysite.test/compose.yml

# 3. Edit wp-config.php
#    - DB_HOST → 'mysql'
#    - Add before "stop editing" line:
#        if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
#            $_SERVER['HTTPS'] = 'on';
#        }

# 4. Regenerate cert with new domain added
cd /tmp && mkcert mysite.test [plus all existing domains...]
cp *.pem ~/WebApps/env-manage/local_infra/traefik/certs/
cd ~/WebApps/env-manage/local_infra && sudo docker compose restart traefik

# 5. Resolve the domain on the host
echo '127.0.0.1 mysite.test' | sudo tee -a /etc/hosts

# 6. Start (first run builds the UID 1000 image)
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
- **WP sites** use `local/wordpress:php8.4-apache-uid1000` (built locally from `wordpress:php8.4-apache`) and `wordpress:cli-php8.4` — tracks the PHP line, not the WP version. WP core lives in the site directory and is updated by WordPress itself; the image only provides PHP + Apache. The built image isn't pulled, so update it with `--pull`, in any one site directory (all sites share the tag), then recreate each site:
  ```bash
  docker compose build --pull wordpress && docker compose up -d
  ```

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
