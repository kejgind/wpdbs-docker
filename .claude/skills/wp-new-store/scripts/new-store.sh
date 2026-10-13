#!/usr/bin/env bash
# Bootstrap a fresh WordPress + WooCommerce store on local_infra.
# Usage: new-store.sh <domain.test> [--locale pl_PL] [--country PL] [--currency PLN]
#                     [--plugins slug1,slug2] [--acf /path/acf-pro.zip] [--reset-db]
# Runs as your user (Sudoless Docker); never needs sudo except the /etc/hosts line it prints.
set -euo pipefail

INFRA="${LOCAL_INFRA:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
WEBAPPS="${WEBAPPS:-$(cd "$INFRA/../.." && pwd)}"
export INFRA_DIR="$INFRA"   # compose mounts; same files as the template's relative default

DOMAIN="${1:-}"; shift || true
LOCALE=pl_PL COUNTRY=PL CURRENCY=PLN PLUGINS="" ACF="" RESET_DB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --locale) LOCALE=$2; shift 2 ;;
    --country) COUNTRY=$2; shift 2 ;;
    --currency) CURRENCY=$2; shift 2 ;;
    --plugins) PLUGINS=$2; shift 2 ;;
    --acf) ACF=$2; shift 2 ;;
    --reset-db) RESET_DB=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ "$DOMAIN" =~ ^[a-z0-9-]+\.test$ ]] || die "domain must look like name.test (got '$DOMAIN')"
NAME=${DOMAIN%.test}
DB=${NAME//-/_}
SITE="$WEBAPPS/$DOMAIN"
CERT="$INFRA/traefik/certs/_wildcard.test.pem"
KEY="$INFRA/traefik/certs/_wildcard.test-key.pem"
DB_CONTAINER=$(grep '^DATABASE_HOST=' "$INFRA/.env" | cut -d= -f2-)
DB_PASS=$(grep '^DATABASE_ROOT_PASSWORD=' "$INFRA/.env" | cut -d= -f2-)
mysql_root() { docker exec -i -e MYSQL_PWD="$DB_PASS" "$DB_CONTAINER" mysql -uroot -N "$@"; }
# The cli image's 128M memory_limit is too small for `core download` (Extractor fatal).
wp() { (cd "$SITE" && docker compose run --rm -T wp-cli php -d memory_limit=512M /usr/local/bin/wp "$@"); }

step "Preflight"
docker info >/dev/null 2>&1 || die "docker not reachable without sudo (enable Sudoless Docker)"
for c in traefik "$DB_CONTAINER"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || die "$c not running — start local_infra first"
done
[ -f "$INFRA/traefik/certs/rootCA.pem" ] || die "traefik/certs/rootCA.pem missing (see README → HTTPS)"
[ -n "$ACF" ] && { [ -f "$ACF" ] || die "ACF zip not found: $ACF"; }
[ ! -e "$SITE" ] || [ -z "$(ls -A "$SITE")" ] || die "$SITE exists and is not empty"
if [ -n "$(mysql_root -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB'")" ]; then
  [ "$RESET_DB" = 1 ] || die "database '$DB' already exists (rerun with --reset-db to drop it)"
  mysql_root -e "DROP DATABASE \`$DB\`"
fi
echo "site=$SITE db=$DB locale=$LOCALE country=$COUNTRY currency=$CURRENCY"

step "Site directory + compose.yml from template"
# Pre-create the mu-plugin mount point as us — Docker would create it (and wp-content) as root.
mkdir -p "$SITE/wp-content/mu-plugins"
touch "$SITE/wp-content/mu-plugins/mailpit-smtp.php"
sed "s/SITE_NAME/$NAME/g; s/SITE_DOMAIN/$DOMAIN/g" "$INFRA/templates/wp-compose.template.yml" > "$SITE/compose.yml"

step "TLS certificate: add $DOMAIN"
mapfile -t SANS < <(openssl x509 -in "$CERT" -noout -ext subjectAltName | grep -o 'DNS:[^,]*' | cut -d: -f2)
if printf '%s\n' "${SANS[@]}" | grep -qx "$DOMAIN"; then
  echo "already in cert"
else
  mkcert -cert-file "$CERT" -key-file "$KEY" "${SANS[@]}" "$DOMAIN"
  docker restart traefik >/dev/null
fi

step "Database"
mysql_root -e "CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"

step "WordPress core + wp-config.php"
wp core download --locale="$LOCALE" --quiet
wp config create --dbname="$DB" --dbuser=root --dbpass="$DB_PASS" --dbhost=mysql --skip-check --extra-php <<'PHP'
define( 'WP_ENVIRONMENT_TYPE', 'local' );
define( 'WP_DEBUG', true );
define( 'WP_DEBUG_DISPLAY', false );
define( 'WP_DEBUG_LOG', true );

// Behind Traefik — trust X-Forwarded-Proto for HTTPS detection.
if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
	$_SERVER['HTTPS'] = 'on';
}
PHP
wp core install --url="https://$DOMAIN" --title="$NAME" --admin_user=admin --admin_password=admin \
  --admin_email="admin@$DOMAIN" --skip-email
wp language core install "$LOCALE" --activate

step "WordPress settings"
wp rewrite structure '/%postname%/' --hard
wp option update timezone_string 'Europe/Warsaw'
wp option update date_format 'j F Y'
wp option update blogdescription ''

step "WooCommerce"
# WC creates its pages on activation, so its translation must be in place first —
# otherwise Shop/Cart/Checkout get English titles and slugs.
wp plugin install woocommerce
wp language plugin install woocommerce "$LOCALE"
wp plugin activate woocommerce
wp wc --user=1 tool run install_pages
wp option update woocommerce_default_country "$COUNTRY"
wp option update woocommerce_currency "$CURRENCY"
wp option update woocommerce_weight_unit kg
wp option update woocommerce_dimension_unit cm
wp option update woocommerce_calc_taxes yes
wp option update woocommerce_prices_include_tax yes

if [ -n "$ACF" ]; then
  step "ACF PRO"
  cp "$ACF" "$SITE/acf-pro.zip"
  wp plugin install /var/www/html/acf-pro.zip --activate
  rm "$SITE/acf-pro.zip"
fi

if [ -n "$PLUGINS" ]; then
  step "Extra plugins"
  wp plugin install ${PLUGINS//,/ } --activate
  wp language plugin install --all "$LOCALE"
fi

step "Cleanup"
wp plugin delete hello akismet --quiet || true
# Fresh install: ID 2 is the sample page, whatever its localized slug.
[ "$(wp post get 2 --field=post_type 2>/dev/null)" != page ] || wp post delete 2 --force

step "Start + verify"
(cd "$SITE" && docker compose up -d --build 2>&1 | tail -1)
for _ in $(seq 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/wp-login.php" || true)
  [ "$code" = 200 ] && break; sleep 2
done
echo "wp-login.php via Traefik: $code"
echo -n "loopback from container: "
(cd "$SITE" && docker compose exec -T wordpress curl -s -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/wp-login.php")
echo -n "wp_mail → Mailpit: "
(cd "$SITE" && docker compose exec -T wordpress php -r "require '/var/www/html/wp-load.php'; echo wp_mail('test@example.com', 'Test from $DOMAIN', 'Mailpit works') ? 'OK' : 'FAIL';"); echo
echo -n "WC pages: "; wp post list --post_type=page --field=post_name | tr '\n' ' '; echo
echo -n "plugins: "; wp plugin list --status=active --field=name | tr '\n' ' '; echo

getent hosts "$DOMAIN" >/dev/null || echo "HOSTS MISSING: echo '127.0.0.1 $DOMAIN' | sudo tee -a /etc/hosts"
[ "$code" = 200 ] || die "site did not answer 200"
echo "DONE https://$DOMAIN/wp-admin/ (admin/admin)"
