# Installation Guide

## Prerequisites

- Linux server (Ubuntu 20.04+, Debian 10+, CentOS/RHEL 7+)
- Bash 4.0 or later
- Root or sudo access
- Internet access for package installation (optional)

## Step 1 - Clone or Download

```bash
git clone https://github.com/ah3san/sshvpnpanel.git
cd sshvpnpanel
```

## Step 2 - Run the Installer

```bash
sudo bash installer.sh
```

The installer will:

1. Detect your Linux distribution
2. Install required packages (`openssh-server`, `stunnel4`, `openssl`, `iptables`, `fail2ban`, etc.)
3. Create system directories (`/etc/sshvpnpanel`, `/var/log/sshvpnpanel`, etc.)
4. Copy configuration files to `/etc/sshvpnpanel/`
5. Initialize the internal TLS Certificate Authority
6. Create the `sshvpn` user group
7. Set script permissions and create `/usr/local/bin/sshvpnpanel` symlink
8. Configure log rotation
9. Set up the Stunnel include-directory architecture
10. Optionally apply SSH hardening and default firewall rules

## Step 3 - Configure

Edit the main configuration file:

```bash
sudo nano /etc/sshvpnpanel/sshvpnpanel.conf
```

Key settings to review:

| Setting | Default | Description |
|---|---|---|
| `SSH_PORT` | `22` | SSH daemon port |
| `SNI_DEFAULT_DOMAIN` | `vpn.example.com` | Default SNI/TLS domain |
| `STUNNEL_PORT_RANGE_START` | `10443` | Start of Stunnel port range |
| `STUNNEL_PORT_RANGE_END` | `20443` | End of Stunnel port range |
| `USER_DEFAULT_GROUP` | `sshvpn` | Linux group for VPN users |
| `SSH_DEFAULT_EXPIRE_DAYS` | `30` | Default account expiry |
| `BANDWIDTH_LIMIT_DEFAULT_MB` | `10240` | Default bandwidth limit |
| `EMAIL_ENABLED` | `false` | Enable email notifications |
| `FIREWALL_BACKEND` | `iptables` | Firewall backend (`iptables` or `ufw`) |

## Step 4 - Verify Installation

```bash
# Check that the command is available
sshvpnpanel --version

# Check service status
sudo sshvpnpanel status

# Launch the interactive panel
sudo sshvpnpanel
```

## Manual Package Installation

If you prefer to install packages manually, you need:

**Ubuntu/Debian:**
```bash
sudo apt-get install -y openssh-server stunnel4 openssl iptables ufw fail2ban vnstat
```

**CentOS/RHEL:**
```bash
sudo yum install -y openssh-server stunnel openssl iptables-services fail2ban
```

For JSON batch import, also install `jq`:
```bash
# Ubuntu/Debian
sudo apt-get install -y jq
# CentOS/RHEL
sudo yum install -y jq
```

## Directory Structure After Installation

```
/etc/sshvpnpanel/            # Configuration files
/var/log/sshvpnpanel/        # Audit and access logs
/var/lib/sshvpnpanel/        # Runtime data (user profiles, bandwidth stats)
/var/backups/sshvpnpanel/    # Backups and archived user data
/etc/stunnel/users/          # Per-user Stunnel configurations
/etc/ssl/sshvpnpanel/        # TLS certificates (CA + per-user)
/usr/local/bin/sshvpnpanel   # Symlink to the main script
```

## Uninstallation

To remove the panel (does not remove SSH users):

```bash
sudo rm -f /usr/local/bin/sshvpnpanel
sudo rm -rf /etc/sshvpnpanel
sudo rm -f /etc/logrotate.d/sshvpnpanel
# Optionally remove logs and data:
# sudo rm -rf /var/log/sshvpnpanel /var/lib/sshvpnpanel
```
