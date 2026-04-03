# SSH VPN Panel

A comprehensive SSH/VPN management panel with support for SSH, Stunnel SSL/TLS, SNI routing, and multi-user management.

## Features

- **SSH User Management** — Create/delete/modify SSH accounts, key management, quota enforcement
- **Stunnel SSL/TLS** — Multi-tunnel configuration, certificate management, auto-restart watchdog
- **TLS/SNI Support** — Server Name Indication routing, multi-domain certificates, Let's Encrypt integration
- **VPN User Management** — Bandwidth limits, expiration dates, online tracking, connection history
- **System Monitoring** — Real-time dashboard, CPU/memory/disk/network stats, alerts
- **Security** — Role-based access control, firewall management (iptables/ufw/firewalld), IP whitelist/blacklist, fail2ban integration
- **Backup & Restore** — Automated backups, encryption, remote backup support
- **Multi-Distro** — Ubuntu 18.04+, Debian 10+, CentOS 7+, RHEL 7+, Alpine Linux 3.12+

## Quick Start

### Installation

```bash
# Clone or download the panel
git clone https://github.com/ah3san/sshvpnpanel.git
cd sshvpnpanel

# Run the installer (as root)
sudo bash installer.sh
```

### Starting the Panel

```bash
sudo sshvpnpanel
# or
sudo /opt/sshvpnpanel/sshvpnpanel.sh
```

### Default Login

```
Username: admin
Password: (set during installation, default: admin123)
```

> **Security Note:** Change the default password immediately after first login.

## File Structure

```
sshvpnpanel/
├── sshvpnpanel.sh              # Main interactive panel
├── installer.sh                # Automated installer
├── modules/
│   ├── utilities.sh            # Shared helper functions, logging, colors
│   ├── ssh_management.sh       # SSH user management
│   ├── stunnel_config.sh       # Stunnel SSL/TLS management
│   ├── tls_sni.sh              # TLS/SNI certificate & routing
│   ├── vpn_users.sh            # VPN user management
│   ├── monitoring.sh           # System monitoring & dashboard
│   └── security.sh             # Security, firewall & authentication
├── config/
│   ├── sshvpnpanel.conf        # Main configuration file
│   ├── stunnel.conf.template   # Stunnel configuration template
│   └── security.conf           # Security configuration
├── logs/                       # Log files (created at runtime)
├── backups/                    # Backup storage
└── docs/
    ├── INSTALLATION.md         # Detailed installation guide
    └── USAGE.md                # Usage documentation
```

## System Requirements

- **OS:** Ubuntu 18.04+, Debian 10+, CentOS 7+, RHEL 7+, Alpine 3.12+
- **Shell:** Bash 4.0+
- **Access:** Root/sudo privileges
- **Packages:** openssh-server, stunnel4/stunnel, openssl (auto-installed)

## Configuration

Edit `/etc/sshvpnpanel/sshvpnpanel.conf` to customize:

```bash
# SSH settings
SSH_PORT=22
MAX_CONNECTIONS_PER_USER=2
DEFAULT_SSH_EXPIRY_DAYS=30

# Stunnel settings
STUNNEL_SSL_PORT=443
STUNNEL_AUTO_RESTART=yes

# TLS settings
DEFAULT_TLS_VERSION=1.3
CERT_RENEW_DAYS=30

# Security settings
MAX_LOGIN_ATTEMPTS=5
ENABLE_FIREWALL=yes
ENABLE_FAIL2BAN=yes
```

## Command-Line Usage

```bash
# Interactive panel
sudo sshvpnpanel

# Non-interactive operations
sudo sshvpnpanel --maintenance       # Run scheduled maintenance
sudo sshvpnpanel --cleanup-expired   # Remove expired users
sudo sshvpnpanel --renew-certs       # Auto-renew certificates
sudo sshvpnpanel --backup            # Create configuration backup
sudo sshvpnpanel --rotate-logs       # Rotate log files
```

## Security

- All admin actions are logged in `/var/log/sshvpnpanel/audit.log`
- Failed login attempts are tracked with automatic IP lockout
- Passwords are stored as SHA-256 hashes
- Role-based access control: `admin`, `operator`, `viewer`
- Firewall rules managed via iptables/ufw/firewalld

## License

MIT License — See [LICENSE](LICENSE) for details.
