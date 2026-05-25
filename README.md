# Secure Laravel VPS Bootstrap

A security-first Bash bootstrap for preparing a fresh Ubuntu VPS for a Laravel application with Nginx, PHP-FPM, Composer, UFW, Fail2ban, Supervisor, and optional HTTPS via Certbot.

Recommended repository name:

```text
secure-laravel-vps-bootstrap
```

## What this repository does

This repository gives you a repeatable one-command workflow for a fresh VPS. It prepares the server so that you can later place your Laravel project inside `/var/www/<project>` and serve it through Nginx with PHP-FPM.

The installer is intentionally conservative:

- It uses Ubuntu APT packages for PHP 8.3+ instead of silently adding third-party repositories.
- It enables UFW with `deny incoming` as the default policy.
- It opens only SSH, HTTP, and HTTPS ports.
- It does not expose MySQL or Redis to the public internet.
- It configures Nginx to serve only the Laravel `public` directory.
- It blocks access to hidden files and sensitive project files such as `.env`, `.git`, `composer.lock`, and build configuration files.
- It verifies the Composer installer checksum before installing Composer.

## Folder structure

```text
secure-laravel-vps-bootstrap/
├── README.md
├── SECURITY.md
├── .gitignore
├── scripts/
│   ├── install.sh
│   └── verify.sh
└── config/
    ├── fail2ban/
    │   └── laravel-vps.local
    ├── nginx/
    │   └── laravel-site.conf.template
    ├── php/
    │   └── laravel-production.ini
    └── supervisor/
        └── laravel-worker.conf.example
```

## Supported server

Use a fresh Ubuntu Server VPS, preferably Ubuntu 24.04 LTS or newer.

Laravel currently requires PHP 8.3 or newer for the latest major documentation line. This script therefore installs PHP 8.3+ only. If your Ubuntu repositories do not provide PHP 8.3 or PHP 8.4, the installer stops instead of adding an unreviewed third-party package source.

## Before running

1. Point your domain DNS `A` record to the VPS public IP address.
2. SSH into the VPS as a sudo-capable user.
3. Confirm your real SSH port. The default is `22`. If your VPS uses another SSH port, pass it with `--ssh-port` or you may lock yourself out when UFW is enabled.
4. Clone this repository and inspect the script before running it.

Do not run random `curl | bash` commands on a production server. Clone, review, then execute.

## Quick start

Replace the GitHub URL with your own repository URL after you push this project.

```bash
git clone https://github.com/Tahsin000/secure-laravel-vps-bootstrap.git
cd secure-laravel-vps-bootstrap
sudo bash scripts/install.sh --domain example.com --app-dir /var/www/example.com
```

With HTTPS enabled:

```bash
git clone https://github.com/Tahsin000/secure-laravel-vps-bootstrap.git
cd secure-laravel-vps-bootstrap
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --enable-ssl \
  --email admin@example.com
```

If your SSH port is not `22`:

```bash
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --ssh-port 2222
```

Optional local MySQL and Redis:

```bash
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --install-mysql \
  --install-redis
```

## Step-by-step execution flow after clone or pull on VPS

This section is the exact command flow to run after you clone or pull this repository on your VPS.

### Root cause of setup confusion

- The README had quick-start commands and Laravel deployment commands, but not one dedicated execution runbook.
- The old deploy snippet used `git clone ... .` inside `${APP_DIR}` even though `install.sh` already creates files/directories there, so clone can fail with `destination path '.' already exists and is not an empty directory`.
- The flow did not clearly separate one-time server bootstrap from repeat Laravel deployments.

### 1. One-time VPS bootstrap (run once per server)

```bash
cd ~/secure-laravel-vps-bootstrap
git pull --ff-only

sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --php-version auto \
  --ssh-port 22
```

With HTTPS:

```bash
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --php-version auto \
  --ssh-port 22 \
  --enable-ssl \
  --email admin@example.com
```

### 2. One-time Laravel app deploy into the prepared app directory

```bash
export APP_DIR=/var/www/example.com
export APP_REPO=https://github.com/your-org/your-laravel-app.git
export PHP_FPM_SERVICE=php8.3-fpm

sudo rm -f "${APP_DIR}/public/index.html"
sudo rm -rf /tmp/laravel-app-src
sudo git clone "${APP_REPO}" /tmp/laravel-app-src
sudo cp -a /tmp/laravel-app-src/. "${APP_DIR}/"
sudo rm -rf /tmp/laravel-app-src

sudo chown -R "$USER":www-data "${APP_DIR}"
cd "${APP_DIR}"

composer install --no-dev --optimize-autoloader
cp .env.example .env
php artisan key:generate
php artisan migrate --force
php artisan storage:link
php artisan config:cache
php artisan route:cache
php artisan view:cache

sudo chown -R www-data:www-data storage bootstrap/cache
sudo chmod -R ug+rwX,o-rwx storage bootstrap/cache
sudo systemctl reload nginx
sudo systemctl restart "${PHP_FPM_SERVICE}"
```

### 3. Regular deployment flow (every new app release)

```bash
export APP_DIR=/var/www/example.com
export PHP_FPM_SERVICE=php8.3-fpm

cd "${APP_DIR}"
git pull --ff-only
composer install --no-dev --optimize-autoloader
php artisan migrate --force
php artisan optimize
sudo chown -R www-data:www-data storage bootstrap/cache
sudo chmod -R ug+rwX,o-rwx storage bootstrap/cache
sudo systemctl reload nginx
sudo systemctl restart "${PHP_FPM_SERVICE}"
```

### 4. When you pull updates to this bootstrap repository later

Re-run `install.sh` with the same options. It is designed to be safely re-applied for package/config alignment.

```bash
cd ~/secure-laravel-vps-bootstrap
git pull --ff-only
sudo bash scripts/install.sh --domain example.com --app-dir /var/www/example.com --ssh-port 22
```

Then verify:

```bash
sudo bash scripts/verify.sh 8.3
```

## Installer options

| Option | Required | Default | Purpose |
|---|---:|---|---|
| `--domain example.com` | Yes | none | Sets the Nginx `server_name` for the Laravel site. |
| `--app-dir /var/www/example.com` | No | `/var/www/laravel` | Directory where the Laravel project will live. Must be inside `/var/www/`. |
| `--php-version 8.3` | No | `auto` | Installs a specific PHP version. `auto` tries PHP 8.4, then PHP 8.3. |
| `--ssh-port 22` | No | `22` | Keeps your SSH port open when UFW is enabled. |
| `--enable-ssl` | No | disabled | Installs Certbot and requests an HTTPS certificate through the Nginx plugin. |
| `--email admin@example.com` | Required with SSL | none | Email used for Let's Encrypt registration and expiry notices. |
| `--install-mysql` | No | disabled | Installs MySQL locally. The firewall does not open port `3306`. |
| `--install-redis` | No | disabled | Installs Redis locally and binds it to `127.0.0.1` / `::1`. |

## What gets installed

Core packages:

```bash
apt-transport-https ca-certificates curl fail2ban git gnupg lsb-release nginx software-properties-common supervisor ufw unattended-upgrades unzip
```

PHP packages:

```bash
php8.x-bcmath php8.x-cli php8.x-common php8.x-curl php8.x-fpm php8.x-gd php8.x-intl php8.x-mbstring php8.x-mysql php8.x-opcache php8.x-readline php8.x-redis php8.x-sqlite3 php8.x-xml php8.x-zip
```

Optional packages:

```bash
mysql-server redis-server snapd certbot
```

## Individual command breakdown

This section explains the important commands used by the installer and why each one exists.

| Command | Why it runs |
|---|---|
| `apt-get update -y` | Refreshes the local package index so the VPS installs current packages from configured Ubuntu repositories. |
| `apt-get install -y nginx` | Installs Nginx as the public web server. |
| `apt-get install -y php8.x-fpm php8.x-cli ...` | Installs PHP-FPM, CLI PHP, and Laravel-compatible PHP extensions. |
| `apt-get install -y ufw` | Installs the uncomplicated firewall used to restrict inbound traffic. |
| `ufw default deny incoming` | Blocks all inbound connections unless explicitly allowed. |
| `ufw default allow outgoing` | Allows the server to reach package repositories, DNS, APIs, and external services. |
| `ufw allow <ssh-port>/tcp` | Keeps SSH access available after the firewall is enabled. |
| `ufw allow 80/tcp` | Allows HTTP traffic for Nginx and Let's Encrypt ACME HTTP validation. |
| `ufw allow 443/tcp` | Allows HTTPS traffic for production web access. |
| `ufw --force enable` | Enables the firewall without an interactive prompt. |
| `apt-get install -y fail2ban` | Installs brute-force protection for SSH and selected Nginx abuse patterns. |
| `systemctl enable --now fail2ban` | Starts Fail2ban now and enables it after reboot. |
| `systemctl enable --now nginx` | Starts Nginx now and enables it after reboot. |
| `systemctl enable --now php8.x-fpm` | Starts PHP-FPM now and enables it after reboot. |
| `nginx -t` | Validates Nginx configuration before reload, preventing a broken config from being applied. |
| `systemctl reload nginx` | Applies the new Nginx virtual host without a full service stop. |
| `curl -fsSL https://composer.github.io/installer.sig` | Downloads the official Composer installer checksum. |
| `curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php` | Downloads the Composer installer. |
| `php -r "echo hash_file('sha384', '/tmp/composer-setup.php');"` | Calculates the installer hash locally for verification. |
| `php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer` | Installs Composer globally only after checksum verification succeeds. |
| `install -d -m 0755 -o root -g root /var/www/<project>/public` | Creates the web root with safe default ownership and permissions. |
| `install -d -m 0775 -o www-data -g www-data /var/www/<project>/storage` | Creates Laravel's writable storage directory for logs, cache, sessions, and uploads. |
| `install -d -m 0775 -o www-data -g www-data /var/www/<project>/bootstrap/cache` | Creates Laravel's writable bootstrap cache directory. |
| `ln -sfn /etc/nginx/sites-available/<site>.conf /etc/nginx/sites-enabled/<site>.conf` | Enables the generated Nginx site. |
| `rm -f /etc/nginx/sites-enabled/default` | Disables the default Nginx site to avoid exposing the placeholder page. |
| `sysctl --system` | Applies conservative kernel network hardening settings. |
| `apt-get install -y unattended-upgrades` | Enables automatic security updates. |
| `snap install --classic certbot` | Installs Certbot using the officially recommended Snap flow when SSL is requested. |
| `certbot --nginx -d example.com --redirect` | Requests a certificate and configures Nginx HTTPS redirect automatically. |
| `certbot renew --dry-run` | Tests automatic certificate renewal. |

## Nginx security model

The generated Nginx site points to:

```text
/var/www/<project>/public
```

This matters because Laravel's `.env`, `vendor`, `storage`, `bootstrap`, and source files live outside the public web root. Nginx should never serve the whole Laravel project directory.

Additional Nginx protection in this repository:

```nginx
location ~ /\. {
    deny all;
}

location ~* /(\.env|\.git|composer\.(json|lock)|package(-lock)?\.json|vite\.config\.|webpack\.mix\.|phpunit\.xml|server\.php) {
    deny all;
}
```

These rules block common sensitive files even if a deployment mistake places them somewhere reachable.

## Firewall policy

The installer uses this inbound policy:

```text
Default incoming: deny
Default outgoing: allow
Allowed inbound: SSH port, 80/tcp, 443/tcp
```

It does not open these ports:

```text
3306/tcp  MySQL
5432/tcp  PostgreSQL
6379/tcp  Redis
9000/tcp  PHP-FPM
```

PHP-FPM is reached through a Unix socket:

```text
/run/php/php8.x-fpm.sock
```

That avoids exposing PHP-FPM directly to the network.

## Deploying your Laravel project after bootstrap

Use the dedicated runbook in `Step-by-step execution flow after clone or pull on VPS`.

## Enabling Laravel queue workers

The installer writes a disabled Supervisor example here:

```text
/etc/supervisor/conf.d/laravel-worker.conf.example
```

After your Laravel app is deployed, enable it like this:

```bash
sudo cp /etc/supervisor/conf.d/laravel-worker.conf.example /etc/supervisor/conf.d/laravel-worker.conf
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl status
```

## Verification

Run the verification script after installation:

```bash
sudo bash scripts/verify.sh 8.3
```

It checks:

- OS version
- Service status
- Nginx config validity
- PHP version and modules
- Composer version
- UFW firewall status
- Listening TCP ports

## Production notes

- Create a non-root deploy user for routine deployments.
- Keep `.env` out of Git.
- Use strong database passwords.
- Use SSH keys instead of password SSH login.
- Do not expose database, Redis, or PHP-FPM ports publicly.
- Keep backups before running migrations.
- Review `/var/log/nginx/`, `/var/log/fail2ban.log`, and Laravel logs regularly.

## References

- Laravel deployment requirements: `https://laravel.com/docs/13.x/deployment`
- Laravel installation notes for Composer and Node/NPM or Bun: `https://laravel.com/docs/13.x/installation`
- Certbot Nginx instructions: `https://certbot.eff.org/instructions`
