#!/usr/bin/env bash
set -Eeuo pipefail

# Secure Laravel VPS Bootstrap
# Target OS: Ubuntu Server 24.04 LTS or newer with APT-managed PHP >= 8.3.

export DEBIAN_FRONTEND=noninteractive

DOMAIN=""
APP_DIR="/var/www/laravel"
PHP_VERSION="auto"
SSH_PORT="22"
EMAIL=""
ENABLE_SSL="false"
INSTALL_MYSQL="false"
INSTALL_REDIS="false"
SITE_ID=""
AUTO_FELL_BACK_TO_83="false"

log() {
  printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33m[!] %s\033[0m\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Secure Laravel VPS Bootstrap

Usage:
  sudo bash scripts/install.sh --domain example.com [options]

Required:
  --domain DOMAIN             Domain name pointed to this VPS, e.g. app.example.com

Options:
  --app-dir PATH              Laravel application directory. Default: /var/www/laravel
  --php-version VERSION       PHP version to install. Default: auto, tries 8.4 then 8.3
  --ssh-port PORT             SSH port to keep open in UFW. Default: 22
  --enable-ssl                Install Certbot and request HTTPS certificate with Nginx
  --email EMAIL               Email for Let's Encrypt registration. Required with --enable-ssl
  --install-mysql             Install MySQL server locally. MySQL port is NOT opened in UFW
  --install-redis             Install Redis locally and bind it to localhost only
  -h, --help                  Show this help

Examples:
  sudo bash scripts/install.sh --domain example.com --app-dir /var/www/example.com
  sudo bash scripts/install.sh --domain example.com --enable-ssl --email admin@example.com
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root with sudo."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2:-}"; shift 2 ;;
      --app-dir)
        APP_DIR="${2:-}"; shift 2 ;;
      --php-version)
        PHP_VERSION="${2:-}"; shift 2 ;;
      --ssh-port)
        SSH_PORT="${2:-}"; shift 2 ;;
      --enable-ssl)
        ENABLE_SSL="true"; shift ;;
      --email)
        EMAIL="${2:-}"; shift 2 ;;
      --install-mysql)
        INSTALL_MYSQL="true"; shift ;;
      --install-redis)
        INSTALL_REDIS="true"; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1" ;;
    esac
  done
}

validate_input() {
  [[ -n "${DOMAIN}" ]] || die "--domain is required."
  [[ "${DOMAIN}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Invalid domain: ${DOMAIN}"
  [[ "${APP_DIR}" == /var/www/* ]] || die "For safety, --app-dir must be inside /var/www/."
  [[ "${APP_DIR}" != *".."* ]] || die "Invalid --app-dir path."
  [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "--ssh-port must be a number."
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "--ssh-port must be between 1 and 65535."
  if [[ "${ENABLE_SSL}" == "true" && -z "${EMAIL}" ]]; then
    die "--email is required when --enable-ssl is used."
  fi
  if [[ -n "${EMAIL}" ]]; then
    [[ "${EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Invalid email: ${EMAIL}"
  fi
  SITE_ID="$(printf '%s' "${DOMAIN}" | sed 's/[^A-Za-z0-9._-]/_/g')"
}

check_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS. This script requires Ubuntu with apt."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Ubuntu Server 24.04 LTS or newer."
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
}

apt_update_once() {
  log "Updating APT package index"
  apt-get update -y
}

package_available() {
  local package="$1"
  apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq '(none)'
}

select_php_version() {
  if [[ "${PHP_VERSION}" != "auto" ]]; then
    [[ "${PHP_VERSION}" =~ ^8\.[3-9]$ ]] || die "PHP version must be 8.3 or newer, e.g. 8.3 or 8.4."
    package_available "php${PHP_VERSION}-fpm" || die "php${PHP_VERSION}-fpm is not available from your current APT repositories. Use Ubuntu 24.04+ or provide a supported PHP version."
    return
  fi

  local candidate
  for candidate in 8.4 8.3; do
    if package_available "php${candidate}-fpm"; then
      PHP_VERSION="${candidate}"
      log "Selected PHP ${PHP_VERSION} from Ubuntu repositories"
      if [[ "${candidate}" == "8.3" ]]; then
        AUTO_FELL_BACK_TO_83="true"
      fi
      return
    fi
  done

  die "No APT-managed PHP >= 8.3 package was found. Use Ubuntu 24.04+ or add a trusted PHP repository manually before running."
}

install_base_packages() {
  log "Installing base server packages"
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    fail2ban \
    git \
    gnupg \
    lsb-release \
    nginx \
    software-properties-common \
    supervisor \
    ufw \
    unattended-upgrades \
    unzip
}

install_php_packages() {
  log "Installing PHP ${PHP_VERSION}, PHP-FPM, and Laravel-ready extensions"
  apt-get install -y \
    "php${PHP_VERSION}-bcmath" \
    "php${PHP_VERSION}-cli" \
    "php${PHP_VERSION}-common" \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-intl" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-mysql" \
    "php${PHP_VERSION}-opcache" \
    "php${PHP_VERSION}-readline" \
    "php${PHP_VERSION}-redis" \
    "php${PHP_VERSION}-sqlite3" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-zip"
}

install_optional_datastores() {
  if [[ "${INSTALL_MYSQL}" == "true" ]]; then
    log "Installing MySQL server for local-only database usage"
    apt-get install -y mysql-server
    systemctl enable --now mysql
  fi

  if [[ "${INSTALL_REDIS}" == "true" ]]; then
    log "Installing and hardening Redis for localhost-only usage"
    apt-get install -y redis-server
    if [[ -f /etc/redis/redis.conf ]]; then
      sed -i 's/^#\? *bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
      sed -i 's/^#\? *protected-mode .*/protected-mode yes/' /etc/redis/redis.conf
      sed -i 's/^#\? *supervised .*/supervised systemd/' /etc/redis/redis.conf
    fi
    systemctl enable --now redis-server
    systemctl restart redis-server
  fi
}

install_composer() {
  if command -v composer >/dev/null 2>&1; then
    log "Composer is already installed: $(composer --version --no-ansi 2>/dev/null || true)"
    return
  fi

  log "Installing Composer with installer checksum verification"
  local installer="/tmp/composer-setup.php"
  local expected actual
  expected="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL https://getcomposer.org/installer -o "${installer}"
  actual="$(php -r "echo hash_file('sha384', '${installer}');")"

  if [[ "${expected}" != "${actual}" ]]; then
    rm -f "${installer}"
    die "Composer installer checksum verification failed."
  fi

  php "${installer}" --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f "${installer}"
  composer --version --no-ansi
}

configure_php() {
  log "Applying PHP-FPM security and production settings"
  local ini_content
  read -r -d '' ini_content <<PHPINI || true
expose_php = Off
cgi.fix_pathinfo = 0
display_errors = Off
log_errors = On
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
opcache.enable = 1
opcache.enable_cli = 0
opcache.validate_timestamps = 0
realpath_cache_size = 4096K
realpath_cache_ttl = 600
PHPINI

  printf '%s\n' "${ini_content}" > "/etc/php/${PHP_VERSION}/fpm/conf.d/99-laravel-production.ini"
  printf '%s\n' "${ini_content}" > "/etc/php/${PHP_VERSION}/cli/conf.d/99-laravel-production.ini"
  systemctl enable --now "php${PHP_VERSION}-fpm"
  systemctl restart "php${PHP_VERSION}-fpm"
}

configure_app_directory() {
  log "Preparing Laravel application directory at ${APP_DIR}"
  install -d -m 0755 -o root -g root "${APP_DIR}"
  install -d -m 0755 -o root -g root "${APP_DIR}/public"
  install -d -m 0775 -o www-data -g www-data "${APP_DIR}/storage"
  install -d -m 0775 -o www-data -g www-data "${APP_DIR}/bootstrap/cache"

  if [[ ! -f "${APP_DIR}/public/index.php" && ! -f "${APP_DIR}/public/index.html" ]]; then
    cat > "${APP_DIR}/public/index.html" <<PLACEHOLDER
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Laravel VPS Ready</title></head>
<body><h1>Laravel VPS environment is ready.</h1><p>Deploy your Laravel project to ${APP_DIR}.</p></body>
</html>
PLACEHOLDER
    chown root:root "${APP_DIR}/public/index.html"
    chmod 0644 "${APP_DIR}/public/index.html"
  fi
}

configure_nginx() {
  log "Configuring Nginx virtual host for ${DOMAIN}"
  cat > /etc/nginx/conf.d/00-security-baseline.conf <<'NGINXSECURITY'
server_tokens off;
NGINXSECURITY

  cat > "/etc/nginx/sites-available/${SITE_ID}.conf" <<NGINXCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${APP_DIR}/public;
    index index.php index.html;

    charset utf-8;
    client_max_body_size 64M;

    access_log /var/log/nginx/${SITE_ID}-access.log;
    error_log  /var/log/nginx/${SITE_ID}-error.log warn;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\. {
        deny all;
    }

    location ~* /(\.env|\.git|composer\.(json|lock)|package(-lock)?\.json|vite\.config\.|webpack\.mix\.|phpunit\.xml|server\.php) {
        deny all;
    }
}
NGINXCONF

  ln -sfn "/etc/nginx/sites-available/${SITE_ID}.conf" "/etc/nginx/sites-enabled/${SITE_ID}.conf"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

configure_firewall() {
  log "Configuring UFW firewall: deny incoming by default, allow SSH/HTTP/HTTPS only"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'SSH access'
  ufw allow 80/tcp comment 'HTTP for Nginx and ACME challenge'
  ufw allow 443/tcp comment 'HTTPS for Nginx'
  ufw --force enable
  ufw status verbose
}

configure_fail2ban() {
  log "Configuring Fail2ban for SSH and Nginx abuse protection"
  cat > /etc/fail2ban/jail.d/laravel-vps.local <<FAIL2BAN
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
FAIL2BAN

  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

configure_unattended_upgrades() {
  log "Enabling unattended security upgrades"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTCONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTCONF
}

configure_sysctl() {
  log "Applying conservative kernel network hardening"
  cat > /etc/sysctl.d/99-laravel-vps-hardening.conf <<'SYSCTL'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
SYSCTL
  sysctl --system >/dev/null
}

write_supervisor_template() {
  log "Writing disabled Supervisor template for Laravel queue workers"
  cat > /etc/supervisor/conf.d/laravel-worker.conf.example <<SUPERVISOR
[program:laravel-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/worker.log
stopwaitsecs=3600
SUPERVISOR
  systemctl enable --now supervisor
  systemctl restart supervisor
}

install_ssl_certificate() {
  if [[ "${ENABLE_SSL}" != "true" ]]; then
    warn "SSL was not requested. Run again with --enable-ssl --email you@example.com after DNS points to this server."
    return
  fi

  log "Installing Certbot via Snap and requesting HTTPS certificate"
  apt-get install -y snapd
  systemctl enable --now snapd.socket
  snap install core >/dev/null 2>&1 || snap refresh core
  snap install --classic certbot
  ln -sfn /snap/bin/certbot /usr/bin/certbot

  certbot --nginx \
    -d "${DOMAIN}" \
    --agree-tos \
    --email "${EMAIL}" \
    --redirect \
    --no-eff-email \
    --non-interactive

  systemctl reload nginx
  certbot renew --dry-run
}

print_summary() {
  cat <<SUMMARY

============================================================
Secure Laravel VPS bootstrap completed.
============================================================
Domain:      ${DOMAIN}
App path:    ${APP_DIR}
Web root:    ${APP_DIR}/public
PHP-FPM:     PHP ${PHP_VERSION}
Nginx site:  /etc/nginx/sites-available/${SITE_ID}.conf
Firewall:    UFW enabled; inbound default deny; allowed ${SSH_PORT}/tcp, 80/tcp, 443/tcp
SSL:         ${ENABLE_SSL}
MySQL:       ${INSTALL_MYSQL}
Redis:       ${INSTALL_REDIS}

Next deployment steps:
  1. Upload or git clone your Laravel project into ${APP_DIR}.
  2. Run: cd ${APP_DIR} && composer install --no-dev --optimize-autoloader
  3. Create .env safely and run: php artisan key:generate
  4. Re-apply Laravel writable permissions:
     sudo bash scripts/fix-permissions.sh --app-dir ${APP_DIR}
  5. Reload services:
     sudo systemctl reload nginx
     sudo systemctl restart php${PHP_VERSION}-fpm

Use scripts/verify.sh to review service status and exposed ports.
SUMMARY

  if [[ "${AUTO_FELL_BACK_TO_83}" == "true" ]]; then
    cat <<NOTE

Compatibility note:
  - Auto mode selected PHP 8.3 because PHP 8.4 was not available from current APT repositories.
  - Some Laravel 13 lockfiles resolve Symfony 8 packages that require PHP >= 8.4.
  - If 'composer install' fails with 'symfony/* requires php >=8.4', re-run this installer with:
      --php-version 8.4
    and use an Ubuntu/repository source that provides php8.4 packages.
NOTE
  fi
}

main() {
  require_root
  parse_args "$@"
  validate_input
  check_os
  apt_update_once
  select_php_version
  install_base_packages
  install_php_packages
  install_optional_datastores
  install_composer
  configure_php
  configure_app_directory
  configure_nginx
  configure_firewall
  configure_fail2ban
  configure_unattended_upgrades
  configure_sysctl
  write_supervisor_template
  install_ssl_certificate
  print_summary
}

main "$@"
