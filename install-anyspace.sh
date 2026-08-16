#!/usr/bin/env bash
#
# install-anyspace.sh
#
# Unattended installer for AnySpace (https://github.com/superswan/anyspace)
# on a fresh Debian/Ubuntu server. Installs Apache or Nginx + PHP-FPM +
# MariaDB, clones the repo, creates the database and admin account, and
# stands up a virtual host.
#
# Usage:
#   sudo ./install-anyspace.sh --domain example.com
#   sudo ./install-anyspace.sh --help
#
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Defaults (override with flags, see --help)
# ----------------------------------------------------------------------------
DOMAIN=""                          # e.g. anyspace.example.com (blank = use server IP)
ADMIN_DOMAIN=""                    # e.g. admin.example.com (blank = admin panel not web-exposed)
SITE_NAME="AnySpace"
INSTALL_DIR="/var/www/anyspace"
REPO_URL="https://github.com/superswan/anyspace.git"
BRANCH="main"
WEBSERVER="nginx"                  # nginx | apache
DB_NAME="anyspace"
DB_USER="anyspace"
DB_PASS=""                         # blank = auto-generate
ADMIN_USERNAME="admin"
ADMIN_EMAIL=""
ADMIN_PASS=""                      # blank = auto-generate
ENABLE_SSL="no"                    # --ssl to attempt Let's Encrypt via certbot
ENABLE_FIREWALL="yes"
ASSUME_YES="no"
CRED_FILE="/root/anyspace-credentials.txt"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
c_reset="\033[0m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_blue="\033[34m"
info()    { echo -e "${c_blue}[*]${c_reset} $*"; }
success() { echo -e "${c_green}[+]${c_reset} $*"; }
warn()    { echo -e "${c_yellow}[!]${c_reset} $*"; }
die()     { echo -e "${c_red}[x]${c_reset} $*" >&2; exit 1; }

on_error() {
  local line=$1
  die "Install failed at line $line. Nothing after that point was applied; re-run after fixing the issue is safe to retry (existing install dir will need to be removed first)."
}
trap 'on_error $LINENO' ERR

random_string() {
  # 20-char alnum string. The `|| true` matters: head -c closes the pipe
  # once it has enough bytes, which sends tr a SIGPIPE (exit 141) even
  # though the output itself is already complete and correct — without
  # `|| true`, `set -o pipefail` would treat that as a real failure and
  # abort the whole script under `set -e`.
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-20}" || true
}

sql_escape() {
  # Escape single quotes for use inside a SQL '...' literal
  printf '%s' "$1" | sed "s/'/''/g"
}

usage() {
  cat <<EOF
AnySpace auto-installer

Usage: sudo $0 [options]

  --domain DOMAIN          Public domain/hostname for the site (default: server IP)
  --admin-domain DOMAIN     Also stand up a separate vhost for the /admin panel
                            (default: admin panel is left off the web entirely)
  --site-name NAME          Display name for the site (default: AnySpace)
  --install-dir PATH        Where to clone the app (default: /var/www/anyspace)
  --branch BRANCH           Git branch/tag to check out (default: main)
  --webserver nginx|apache  Which web server to configure (default: nginx)
  --db-name NAME             MySQL database name (default: anyspace)
  --db-user NAME             MySQL database user (default: anyspace)
  --db-pass PASS             MySQL database password (default: random)
  --admin-username NAME      Initial AnySpace admin username (default: admin)
  --admin-email EMAIL        Initial AnySpace admin email (default: admin@DOMAIN)
  --admin-pass PASS          Initial AnySpace admin password (default: random)
  --ssl                      Attempt to obtain a Let's Encrypt cert via certbot
                              (requires --domain to already point at this server)
  --no-firewall               Skip ufw firewall rule setup
  -y, --yes                   Don't prompt for confirmation before installing
  -h, --help                   Show this help text

Example:
  sudo $0 --domain social.example.com --admin-domain admin.example.com --ssl -y
EOF
}

# ----------------------------------------------------------------------------
# Parse flags
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --admin-domain) ADMIN_DOMAIN="$2"; shift 2 ;;
    --site-name) SITE_NAME="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --webserver) WEBSERVER="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; shift 2 ;;
    --db-pass) DB_PASS="$2"; shift 2 ;;
    --admin-username) ADMIN_USERNAME="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
    --ssl) ENABLE_SSL="yes"; shift ;;
    --no-firewall) ENABLE_FIREWALL="no"; shift ;;
    -y|--yes) ASSUME_YES="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

[[ "$WEBSERVER" == "nginx" || "$WEBSERVER" == "apache" ]] || die "--webserver must be 'nginx' or 'apache'"

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "This script must be run as root (try: sudo $0 ...)"

[[ -r /etc/os-release ]] || die "Cannot detect OS (no /etc/os-release). This script supports Debian/Ubuntu only."
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  *debian*|*ubuntu*) : ;;
  *) die "Unsupported OS ('${PRETTY_NAME:-unknown}'). This script supports Debian/Ubuntu only." ;;
esac

[[ -e "$INSTALL_DIR" ]] && die "Install directory '$INSTALL_DIR' already exists. Remove it or pass a different --install-dir."

if [[ -z "$DOMAIN" ]]; then
  SERVER_ADDR="$(curl -fsSL -4 --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
  VHOST_NAME="${SERVER_ADDR:-_}"
  warn "No --domain given; the site will be configured for server address '$VHOST_NAME'."
else
  VHOST_NAME="$DOMAIN"
fi

[[ -n "$ADMIN_EMAIL" ]] || ADMIN_EMAIL="admin@${DOMAIN:-example.com}"
[[ -n "$DB_PASS" ]] || DB_PASS="$(random_string 24)"
[[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="$(random_string 16)"

if [[ "$ENABLE_SSL" == "yes" && -z "$DOMAIN" ]]; then
  warn "--ssl requires --domain to be set; disabling SSL step."
  ENABLE_SSL="no"
fi

# ----------------------------------------------------------------------------
# Confirm
# ----------------------------------------------------------------------------
cat <<SUMMARY

  AnySpace will be installed with the following settings:

  Site URL        : http://${VHOST_NAME}/  $( [[ $ENABLE_SSL == yes ]] && echo "(https after cert issuance)" )
  Admin panel URL : $( [[ -n "$ADMIN_DOMAIN" ]] && echo "http://${ADMIN_DOMAIN}/" || echo "(not exposed publicly — see notes at the end)" )
  Web server      : $WEBSERVER
  Install dir     : $INSTALL_DIR
  Database        : $DB_NAME (user: $DB_USER)
  Admin account   : $ADMIN_USERNAME <$ADMIN_EMAIL>

SUMMARY

if [[ "$ASSUME_YES" != "yes" ]]; then
  read -r -p "Proceed with installation? [y/N] " REPLY
  [[ "$REPLY" =~ ^[Yy]$ ]] || die "Aborted."
fi

# ----------------------------------------------------------------------------
# 1. Packages
# ----------------------------------------------------------------------------
info "Updating package index..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

info "Installing base packages (git, curl, PHP-FPM, MariaDB)..."
apt-get install -y git curl ca-certificates \
  php-fpm php-cli php-mysql php-mbstring php-curl php-xml php-zip php-gd \
  mariadb-server

if [[ "$WEBSERVER" == "nginx" ]]; then
  apt-get install -y nginx
else
  apt-get install -y apache2
  a2enmod rewrite proxy_fcgi setenvif >/dev/null
fi

PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
info "Detected PHP ${PHP_VER}, PHP-FPM socket: ${PHP_SOCK}"

systemctl enable --now "php${PHP_VER}-fpm" mariadb >/dev/null

# ----------------------------------------------------------------------------
# 2. Database
# ----------------------------------------------------------------------------
info "Creating database and database user..."
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '$(sql_escape "$DB_PASS")';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# ----------------------------------------------------------------------------
# 3. Fetch the app
# ----------------------------------------------------------------------------
info "Cloning AnySpace (branch: ${BRANCH})..."
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"

info "Loading database schema..."
# NOTE: we intentionally use the schema exactly as embedded in the project's
# own public/install.php (the official web installer) rather than the
# bundled anyspace.sql/schema.sql files. As of this writing those two files
# declare users.lastactive/lastlogon as NOT NULL with no default, which the
# app's own install/admin-creation flow violates (it inserts NULL for both
# on account creation) — install.php's inline copy fixes this with
# NULL DEFAULT NULL. Using install.php's version keeps this script correct
# even though it duplicates SQL that in principle should live in one place.
mysql -u root "$DB_NAME" <<'SQL'
CREATE TABLE IF NOT EXISTS `blogs` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `text` text NOT NULL,
    `author` varchar(255) NOT NULL,
    `date` datetime NOT NULL,
    `title` varchar(255) NOT NULL,
    `kudos` int(11) DEFAULT '0',
    `category` int(11) NOT NULL,
    `privacy_level` int(11) NOT NULL,
    `pinned` tinyint(1) NOT NULL DEFAULT '0',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `blogcomments` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `toid` int(11) NOT NULL,
    `parent_id` int(11) DEFAULT NULL,
    `author` varchar(255) NOT NULL,
    `text` varchar(500) NOT NULL,
    `date` datetime NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `bulletins` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `text` text NOT NULL,
    `author` varchar(255) NOT NULL,
    `date` datetime NOT NULL,
    `title` varchar(255) NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `bulletincomments` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `toid` int(11) NOT NULL,
    `parent_id` int(11) NOT NULL,
    `author` varchar(255) NOT NULL,
    `text` varchar(500) NOT NULL,
    `date` datetime NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `comments` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `toid` int(11) NOT NULL,
    `parent_id` int(11) NOT NULL,
    `author` varchar(255) NOT NULL,
    `text` varchar(500) NOT NULL,
    `date` datetime NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `favorites` (
    `user_id` int(11) NOT NULL,
    `favorites` text,
    PRIMARY KEY (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `friends` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `sender` varchar(255) NOT NULL,
    `receiver` varchar(255) NOT NULL,
    `status` varchar(255) NOT NULL DEFAULT 'PENDING',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `groupcomments` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `toid` int(11) NOT NULL,
    `author` varchar(255) NOT NULL,
    `text` varchar(500) NOT NULL,
    `date` datetime NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `groups` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `name` varchar(255) NOT NULL,
    `description` varchar(500) NOT NULL,
    `author` varchar(255) NOT NULL,
    `date` datetime NOT NULL,
    `members` text NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `layoutcomments` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `toid` int(11) NOT NULL,
    `author` varchar(255) NOT NULL,
    `text` varchar(500) NOT NULL,
    `date` datetime NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `layouts` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `text` text NOT NULL,
    `author` varchar(255) NOT NULL,
    `date` datetime NOT NULL,
    `title` varchar(255) NOT NULL,
    `code` blob NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `messages` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `toid` int(11) NOT NULL,
    `author` int(11) NOT NULL,
    `msg` text NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `reports` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `user_id` int(11) NOT NULL,
    `creator_id` int(11) NOT NULL,
    `date` datetime NOT NULL,
    `content_type` int(11) NOT NULL,
    `content_id` int(11) NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `sessions` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `session_id` varchar(16) NOT NULL,
    `user_id` int(11) NOT NULL,
    `user` varchar(50) NOT NULL,
    `last_logon` datetime NULL DEFAULT NULL,
    `last_activity` datetime NULL DEFAULT NULL,
    `active` tinyint(1) NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `users` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `rank` tinyint(4) NOT NULL DEFAULT '0',
    `username` varchar(255) NOT NULL,
    `email` varchar(255) NOT NULL,
    `password` varchar(255) NOT NULL,
    `date` datetime NOT NULL,
    `lastactive` datetime NULL DEFAULT NULL,
    `lastlogon` datetime NULL DEFAULT NULL,
    `bio` varchar(500) NOT NULL DEFAULT '',
    `interests` varchar(500) NOT NULL DEFAULT ' ',
    `css` blob NOT NULL,
    `music` varchar(255) NOT NULL DEFAULT 'default.mp3',
    `pfp` varchar(255) NOT NULL DEFAULT 'default.jpg',
    `currentgroup` varchar(255) NOT NULL DEFAULT 'None',
    `status` varchar(255) NOT NULL DEFAULT '',
    `private` tinyint(1) NOT NULL DEFAULT '0',
    `views` int(11) NOT NULL DEFAULT '0',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
SQL

# ----------------------------------------------------------------------------
# 4. Configure the app
# ----------------------------------------------------------------------------
info "Writing core/config.php..."
cat > "$INSTALL_DIR/core/config.php" <<PHP
<?php
// Database configuration
\$host = 'localhost';
\$dbname = '${DB_NAME}';
\$username = '${DB_USER}';
\$password = '$(printf '%s' "$DB_PASS" | sed "s/'/\\\\'/g")';

// Site localization
\$siteName = "$(printf '%s' "$SITE_NAME" | sed 's/"/\\"/g')";
\$domainName = "$(printf '%s' "${DOMAIN:-$VHOST_NAME}" | sed 's/"/\\"/g')";
\$adminUser = 1;

?>
PHP

info "Creating the admin account (id 1)..."
ADMIN_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$ADMIN_PASS")"
mysql -u root "$DB_NAME" <<SQL
INSERT INTO \`users\`
  (\`id\`, \`rank\`, \`username\`, \`email\`, \`password\`, \`date\`, \`lastactive\`, \`lastlogon\`,
   \`bio\`, \`interests\`, \`css\`, \`music\`, \`pfp\`, \`currentgroup\`, \`status\`, \`private\`, \`views\`)
VALUES
  (1, 1, '$(sql_escape "$ADMIN_USERNAME")', '$(sql_escape "$ADMIN_EMAIL")', '$(sql_escape "$ADMIN_HASH")', NOW(), NULL, NULL,
   '', ' ', '', 'default.mp3', 'default.jpg', 'None', '', 0, 0)
ON DUPLICATE KEY UPDATE \`id\`=\`id\`;
SQL

# The bundled web installer is now redundant (and self-disables once
# core/config.php exists) — remove it so it's one less thing to worry about.
rm -f "$INSTALL_DIR/public/install.php"

# ----------------------------------------------------------------------------
# 5. Permissions
# ----------------------------------------------------------------------------
info "Setting file ownership and permissions..."
WEB_USER="www-data"
chown -R "${WEB_USER}:${WEB_USER}" "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
find "$INSTALL_DIR" -type f -exec chmod 644 {} \;
chmod -R 775 "$INSTALL_DIR/core" "$INSTALL_DIR/public/media/pfp" "$INSTALL_DIR/public/media/music"

# ----------------------------------------------------------------------------
# 6. Web server virtual host(s)
# ----------------------------------------------------------------------------
write_nginx_vhost() {
  local name="$1" docroot="$2"
  local conf="/etc/nginx/sites-available/${name}.conf"
  cat > "$conf" <<NGINX
server {
    listen 80;
    server_name ${name};

    root ${docroot};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    error_log /var/log/nginx/${name}-error.log;
    access_log /var/log/nginx/${name}-access.log;
}
NGINX
  ln -sf "$conf" "/etc/nginx/sites-enabled/${name}.conf"
}

write_apache_vhost() {
  local name="$1" docroot="$2"
  local conf="/etc/apache2/sites-available/${name}.conf"
  cat > "$conf" <<APACHE
<VirtualHost *:80>
    ServerName ${name}
    DocumentRoot ${docroot}

    <Directory ${docroot}>
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php\$>
        SetHandler "proxy:unix:${PHP_SOCK}|fcgi://localhost"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${name}-error.log
    CustomLog \${APACHE_LOG_DIR}/${name}-access.log combined
</VirtualHost>
APACHE
  a2ensite "${name}.conf" >/dev/null
}

info "Configuring ${WEBSERVER} virtual host for ${VHOST_NAME}..."
if [[ "$WEBSERVER" == "nginx" ]]; then
  write_nginx_vhost "$VHOST_NAME" "$INSTALL_DIR/public"
  [[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
else
  write_apache_vhost "$VHOST_NAME" "$INSTALL_DIR/public"
  a2dissite 000-default.conf >/dev/null 2>&1 || true
  apache2ctl configtest
  systemctl reload apache2
fi

if [[ -n "$ADMIN_DOMAIN" ]]; then
  info "Configuring ${WEBSERVER} virtual host for admin panel at ${ADMIN_DOMAIN}..."
  if [[ "$WEBSERVER" == "nginx" ]]; then
    write_nginx_vhost "$ADMIN_DOMAIN" "$INSTALL_DIR/admin"
    nginx -t && systemctl reload nginx
  else
    write_apache_vhost "$ADMIN_DOMAIN" "$INSTALL_DIR/admin"
    apache2ctl configtest && systemctl reload apache2
  fi
  warn "The admin panel is now reachable at http://${ADMIN_DOMAIN}/ — put it behind a firewall rule, VPN, or HTTP basic auth before going live."
fi

# ----------------------------------------------------------------------------
# 7. Firewall
# ----------------------------------------------------------------------------
if [[ "$ENABLE_FIREWALL" == "yes" ]] && command -v ufw >/dev/null 2>&1; then
  info "Configuring ufw firewall rules..."
  ufw allow OpenSSH >/dev/null 2>&1 || true
  if [[ "$WEBSERVER" == "nginx" ]]; then
    ufw allow "Nginx Full" >/dev/null 2>&1 || ufw allow 80/tcp
  else
    ufw allow "Apache Full" >/dev/null 2>&1 || ufw allow 80/tcp
  fi
fi

# ----------------------------------------------------------------------------
# 8. Optional TLS via certbot
# ----------------------------------------------------------------------------
if [[ "$ENABLE_SSL" == "yes" ]]; then
  info "Requesting a Let's Encrypt certificate for ${DOMAIN}..."
  apt-get install -y certbot
  if [[ "$WEBSERVER" == "nginx" ]]; then
    apt-get install -y python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" -m "$ADMIN_EMAIL" --agree-tos --redirect -n \
      || warn "certbot failed — DNS for $DOMAIN may not point here yet. Run 'certbot --nginx -d $DOMAIN' manually once it does."
  else
    apt-get install -y python3-certbot-apache
    certbot --apache -d "$DOMAIN" -m "$ADMIN_EMAIL" --agree-tos --redirect -n \
      || warn "certbot failed — DNS for $DOMAIN may not point here yet. Run 'certbot --apache -d $DOMAIN' manually once it does."
  fi
  if [[ "$ENABLE_FIREWALL" == "yes" ]] && command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp >/dev/null 2>&1 || true
  fi
fi

# ----------------------------------------------------------------------------
# 9. Save credentials & summary
# ----------------------------------------------------------------------------
cat > "$CRED_FILE" <<CREDS
AnySpace install credentials — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Keep this file safe, then delete it (rm ${CRED_FILE}).

Site URL        : http://${VHOST_NAME}/
Install dir     : ${INSTALL_DIR}

Database name   : ${DB_NAME}
Database user   : ${DB_USER}
Database pass   : ${DB_PASS}

AnySpace admin login (use this to log in at the site itself, id 1):
  Username: ${ADMIN_USERNAME}
  Email   : ${ADMIN_EMAIL}
  Password: ${ADMIN_PASS}
CREDS
chmod 600 "$CRED_FILE"

success "AnySpace installed successfully."
cat <<SUMMARY

  Site:            http://${VHOST_NAME}/
  Log in as:       ${ADMIN_USERNAME} / ${ADMIN_EMAIL}
  Password:        ${ADMIN_PASS}
  Credentials also saved to: ${CRED_FILE} (chmod 600 — delete once you've noted it)

  Notes:
  - The admin dashboard (core/admin) lives outside the public webroot and is
    $( [[ -n "$ADMIN_DOMAIN" ]] && echo "reachable at http://${ADMIN_DOMAIN}/ — lock this down further before going live." || echo "not reachable over the web at all right now. Re-run with --admin-domain to expose it on its own vhost." )
  - This installed a plain HTTP site$( [[ $ENABLE_SSL == yes ]] && echo " with a Let's Encrypt certificate." || echo ". Re-run with --ssl (and a real --domain pointed at this server) to add HTTPS." )
  - Consider running 'mysql_secure_installation' to harden the MariaDB root account.
  - The project's schema is described as changing frequently pre-1.0; if a
    future git pull throws a PDO exception, check anyspace.sql/schema.sql
    upstream for new tables/columns to apply manually.

SUMMARY
