# SSH VPN Panel

A comprehensive shell-based SSH VPN management panel with full integration for
**SSH**, **Stunnel (SSL/TLS tunneling)**, **TLS/SNI certificates**, **firewall rules**,
**VPN user profiles**, **bandwidth monitoring**, and **audit logging**.

## Quick Start

```bash
# Clone / download and enter the directory
cd sshvpnpanel

# Run the installer (requires root)
sudo bash installer.sh

# Launch the interactive panel
sudo sshvpnpanel

# Or use CLI directly
sudo sshvpnpanel user add
sudo sshvpnpanel user remove USERNAME
sudo sshvpnpanel --help
```

## Project Structure

```
sshvpnpanel/
├── sshvpnpanel.sh          # Main panel entry point
├── installer.sh            # Automated setup script
├── modules/
│   ├── utilities.sh        # Shared helpers, logging, validation
│   ├── user_add.sh         # Comprehensive user add (all services)
│   ├── user_remove.sh      # Comprehensive user remove (all services)
│   ├── ssh_management.sh   # SSH account and key management
│   ├── stunnel_config.sh   # Stunnel SSL/TLS tunnel management
│   ├── tls_sni.sh          # TLS certificate and SNI domain management
│   ├── security.sh         # Firewall, fail2ban, SSH hardening
│   ├── vpn_users.sh        # VPN user profiles and statistics
│   └── monitoring.sh       # System monitoring and bandwidth reporting
├── config/
│   ├── sshvpnpanel.conf    # Main configuration
│   ├── stunnel.conf.template
│   ├── security.conf
│   └── user_template.conf  # Default user template
├── docs/
│   ├── INSTALLATION.md
│   ├── USAGE.md
│   └── FEATURES.md
├── logs/                   # Runtime log directory (gitignored)
└── backups/                # Backup and archive directory (gitignored)
```

## Key Features

- **User Add** – Creates SSH account, generates SSH keys, configures Stunnel tunnel,
  issues TLS certificate, adds SNI domain, adds firewall whitelist entry, creates
  VPN profile, sets up bandwidth monitoring, and optionally sends a welcome email.
- **User Remove** – Removes all of the above, terminates active sessions, archives
  user data for compliance, generates a final audit report.
- **Batch Operations** – Add/remove multiple users from CSV or JSON files.
- **User Suspension/Reactivation** – Lock/unlock accounts without data loss.
- **Trial Users** – Create temporary accounts with short expiry.
- **CSV Export** – Export the full user list with all service metadata.
- **System Dashboard** – Live system stats, service status, active sessions, audit log.

## Documentation

- [Installation Guide](docs/INSTALLATION.md)
- [Usage Guide](docs/USAGE.md)
- [Feature List](docs/FEATURES.md)

## Requirements

- Linux (Ubuntu 20.04+, Debian 10+, CentOS/RHEL 7+)
- Bash 4.0+
- Root / sudo access
- Optional: `openssl`, `stunnel4`, `fail2ban`, `iptables`/`ufw`, `vnstat`, `jq` (for JSON import)

## License

MIT License. See [LICENSE](LICENSE) for details.
