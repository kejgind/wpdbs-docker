# Local Dev Infrastructure

Traefik reverse proxy + MySQL + phpMyAdmin for local WordPress/WooCommerce and other Docker-based projects.

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
  └── phpMyAdmin  → phpmyadmin.test

MySQL 8.4 → shared by all WP sites via "db" Docker network
```

## Services

| Service | Access | Notes |
|---------|--------|-------|
| Traefik dashboard | http://127.0.0.1:8080 | loopback only |
| phpMyAdmin | https://phpmyadmin.test | |
| MySQL | 127.0.0.1:3306 | loopback only, for direct DB tools |

## DNS

dnsmasq resolves all `*.test` → `127.0.0.1`. No `/etc/hosts` entries needed.

Config: `/etc/dnsmasq.conf`
NetworkManager bypass: `/etc/NetworkManager/conf.d/dns-local.conf`

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

# 3. Set permissions
sudo chown -R 33:33 /srv/http/mysite.test

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
