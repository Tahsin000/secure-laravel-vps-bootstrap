# Security Policy

## Security defaults

This repository is designed for a fresh Ubuntu VPS and applies conservative defaults:

- UFW default inbound policy is `deny`.
- Only SSH, HTTP, and HTTPS are opened.
- MySQL and Redis are local-only when installed.
- PHP-FPM is accessed through a Unix socket, not a public TCP port.
- Nginx serves only the Laravel `public` directory.
- Sensitive files such as `.env` and `.git` are denied by Nginx.
- Composer is installed only after checksum verification.

## Recommended operational practices

- Use SSH keys and disable password login after confirming key-based access works.
- Use a separate non-root deploy user for application releases.
- Keep `.env` outside version control.
- Rotate credentials after sharing server access.
- Back up your application and database before production changes.
- Review UFW and listening ports after every deployment.

## Reporting issues

If you find a security problem in this bootstrap, open a private security advisory in the GitHub repository or contact the repository owner directly.
