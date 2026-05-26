#!/usr/bin/env bash
set -Eeuo pipefail

# Re-apply Laravel writable permissions after deployment.

APP_DIR="/var/www/laravel"

log() {
  printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
}

die() {
  printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Laravel Permission Repair

Usage:
  sudo bash scripts/fix-permissions.sh [--app-dir /var/www/example.com]

Options:
  --app-dir PATH   Laravel application directory. Default: /var/www/laravel
  -h, --help       Show this help
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
      --app-dir)
        APP_DIR="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

validate_input() {
  [[ "${APP_DIR}" == /var/www/* ]] || die "For safety, --app-dir must be inside /var/www/."
  [[ "${APP_DIR}" != *".."* ]] || die "Invalid --app-dir path."
  [[ -d "${APP_DIR}" ]] || die "App directory does not exist: ${APP_DIR}"
}

repair_permissions() {
  log "Ensuring Laravel writable directories exist"
  install -d -m 0775 -o www-data -g www-data "${APP_DIR}/storage"
  install -d -m 0775 -o www-data -g www-data "${APP_DIR}/bootstrap/cache"

  log "Applying ownership and permissions to storage and bootstrap/cache"
  chown -R www-data:www-data "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"
  chmod -R ug+rwX,o-rwx "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"
}

main() {
  require_root
  parse_args "$@"
  validate_input
  repair_permissions
  log "Permission repair complete for ${APP_DIR}"
}

main "$@"
