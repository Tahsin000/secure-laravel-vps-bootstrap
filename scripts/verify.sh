#!/usr/bin/env bash
set -Eeuo pipefail

PHP_VERSION="${1:-}"

echo "== OS =="
cat /etc/os-release | grep -E '^(NAME|VERSION)=' || true

echo

echo "== Services =="
for service in nginx fail2ban supervisor; do
  systemctl is-enabled "$service" 2>/dev/null | awk -v s="$service" '{print s " enabled: " $0}' || true
  systemctl is-active "$service" 2>/dev/null | awk -v s="$service" '{print s " active:  " $0}' || true
 done

if [[ -n "$PHP_VERSION" ]]; then
  systemctl is-active "php${PHP_VERSION}-fpm" 2>/dev/null | awk -v s="php${PHP_VERSION}-fpm" '{print s " active:  " $0}' || true
else
  systemctl list-units --type=service --state=running 'php*-fpm.service' --no-pager || true
fi

echo

echo "== Nginx config test =="
nginx -t

echo

echo "== PHP =="
php -v | head -n 2
php -m | sort | grep -E '^(bcmath|curl|ctype|dom|fileinfo|filter|gd|hash|intl|mbstring|mysqli|mysqlnd|openssl|pdo_mysql|pdo_sqlite|redis|session|simplexml|tokenizer|xml|zip)$' || true

echo

echo "== Composer =="
composer --version --no-ansi || true

echo

echo "== Firewall =="
ufw status verbose || true

echo

echo "== Listening TCP ports =="
ss -tulpen | awk 'NR==1 || /LISTEN/'
