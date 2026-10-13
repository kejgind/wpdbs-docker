---
name: wp-new-store
description: Bootstrap a fresh WordPress + WooCommerce store on local_infra (new `.test` site from scratch). Use when the user wants a new local WP/WC shop.
---

Creates `~/WebApps/<domain>/` from the infra template and fully sets up WordPress + WooCommerce via wp-cli. All mechanics live in [`scripts/new-store.sh`](scripts/new-store.sh); it fails fast with a clear `ERROR:` and never needs sudo.

## 1. Gather inputs

Ask in one **AskUserQuestion** batch (skip what the user already gave, e.g. `/wp-new-store mysite.test`):

1. **Domain** — `name.test` (lowercase, digits, `-`). Derived: site dir `~/WebApps/<domain>`, DB `name` with `-` → `_`.
2. **Locale** — default `pl_PL`. For another locale also ask **country** and **currency** (defaults are `PL` / `PLN`).
3. **ACF PRO** — no, or the path to the zip.
4. **Extra plugins** — wp.org slugs, comma-separated, or none.

State the derived values back and get a yes before running anything.

## 2. Run the script

From the repo root (`~/WebApps/env-manage/local_infra`):

```bash
.claude/skills/wp-new-store/scripts/new-store.sh <domain> [--locale xx_XX --country XX --currency XXX] [--acf <zip>] [--plugins a,b]
```

Allow several minutes (downloads core, WooCommerce, translations). Done when it prints `DONE https://<domain>/wp-admin/` with `wp-login.php via Traefik: 200`, loopback `200` and `wp_mail → Mailpit: OK`.

On `ERROR:` read the message and act:
- **database already exists** — ask the user whether to drop it; rerun with `--reset-db` only on a yes.
- **not running / rootCA.pem missing / docker not reachable** — tell the user what to start or fix (see `README.md`), then rerun.
- **exists and is not empty** — ask the user; never delete a site directory yourself.

## 3. Hand off

- If the output has `HOSTS MISSING`, give the user that exact `sudo tee` line to run (it needs their password).
- ACF PRO installed → remind them to activate the license in wp-admin.
- Report: URL `https://<domain>/wp-admin/`, login `admin` / `admin`, locale, WooCommerce pages and active plugins (from the script output), mail at `https://mail.test`. The site is `restart: "no"` — it runs until `docker compose down` in its directory.
