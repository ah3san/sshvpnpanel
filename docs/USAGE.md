# Usage Guide

## Starting the Panel

```bash
sudo sshvpnpanel
```

## Authentication

On first launch, you'll be prompted to log in:
```
Username: admin
Password: (set during installation)
```

Roles:
- **admin** — Full access to all features
- **operator** — Manage users, view monitoring
- **viewer** — Read-only access

## Main Menu

```
  1. SSH User Management        Add/delete/modify SSH accounts
  2. Stunnel Management         SSL/TLS tunnel configuration
  3. TLS/SNI Configuration      Multi-domain SSL & SNI routing
  4. VPN User Management        VPN users, bandwidth & expiry
  5. System Monitoring          Dashboard, stats & alerts
  6. Security Management        Firewall, IP lists & auth
  7. Configuration & Backup     Settings, backup & restore
  8. Quick Dashboard
  9. Check System Alerts
  r. Restart All Services
  l. Lock Screen / Logout
  q. Quit
```

## SSH User Management

Create a new SSH user:
1. Select `1` → SSH User Management
2. Select `1` → Create SSH User
3. Enter username, password, expiry (days), bandwidth limit, max logins

The user will be created as a system user with a restricted shell (`/bin/false` by default), allowing SSH tunneling but no interactive shell access.

### SSH Keys

Generate an SSH key for a user:
1. SSH User Management → SSH Key Management → Generate Key for User
2. Select key type (ed25519 recommended)
3. Save the generated private key securely

### User Quotas

Quotas are enforced automatically:
- **Max logins**: Maximum simultaneous SSH connections
- **Expiry date**: Account automatically suspended on expiry
- **Bandwidth limit**: User suspended when limit exceeded

## Stunnel Management

### Adding a Tunnel

1. Stunnel Management → Add Tunnel
2. Enter tunnel name (e.g., `ssh-ssl`)
3. Accept address (e.g., `0.0.0.0:443`)
4. Connect address (e.g., `127.0.0.1:22`)
5. Select TLS version

The tunnel will route SSL-wrapped connections to your SSH server.

### Certificate Management

- **Self-signed**: Generated automatically when adding a tunnel
- **CA-signed**: Generate a CA, then sign certificates with it
- **Let's Encrypt**: Use `Request Let's Encrypt Certificate` (requires valid domain & port 80)

## TLS/SNI Configuration

SNI routing allows multiple domains on a single port (443):

1. TLS/SNI → Add SNI Route
2. Enter domain name (e.g., `ssh.example.com`)
3. Enter backend (e.g., `127.0.0.1:22`)
4. Select TLS version
5. Certificate is auto-generated if not specified

After adding routes, generate the SNI Stunnel config and restart Stunnel.

## VPN User Management

VPN users are linked to SSH accounts and support additional features:

- **Protocol**: SSH only, Stunnel only, or both
- **Online tracking**: Real-time online/offline status
- **Connection history**: Full log of connect/disconnect events
- **Bandwidth tracking**: Per-user data usage monitoring

## System Monitoring

### Dashboard

Shows real-time:
- CPU, memory, disk usage with progress bars
- Service status (SSH, Stunnel)
- Network interface statistics
- Active connections

### Real-Time Monitor

`System Monitoring → Real-Time Monitor (auto-refresh)` — Updates every 5 seconds.

### Alerts

Alerts are triggered when:
- CPU > 90% (configurable)
- Memory > 90% (configurable)
- Disk > 85% (configurable)
- Services not running
- Certificates expiring within 7 days

## Security Management

### Firewall

Initialize the firewall to apply standard rules:
```
Security Management → Initialize Firewall
```

Supported backends: `iptables`, `ufw`, `firewalld` (configured in `sshvpnpanel.conf`)

### IP Whitelist/Blacklist

- **Whitelist**: IPs always allowed (bypasses firewall blocks)
- **Blacklist**: IPs always blocked via iptables DROP rules

### Fail2ban

Enable fail2ban protection:
```
Security Management → Setup Fail2ban
```

This creates jails for both SSH and Stunnel services.

## Backup & Restore

### Manual Backup

```bash
sudo sshvpnpanel --backup
# or via menu: Configuration & Backup → Create Backup Now
```

Backups are stored in `/var/backups/sshvpnpanel/`.

### Automatic Backups

Configure in `sshvpnpanel.conf`:
```bash
AUTO_BACKUP=yes
BACKUP_FREQUENCY=daily   # daily/weekly/monthly
BACKUP_RETAIN=7          # Number of backups to keep
BACKUP_ENCRYPTION=no     # Encrypt backups
```

### Restore

```
Configuration & Backup → Restore from Backup → Select backup
```

## Command-Line Reference

```bash
sudo sshvpnpanel                     # Interactive mode
sudo sshvpnpanel --maintenance       # Run maintenance tasks (cron)
sudo sshvpnpanel --cleanup-expired   # Remove expired users
sudo sshvpnpanel --renew-certs       # Auto-renew certificates
sudo sshvpnpanel --backup            # Create backup
sudo sshvpnpanel --rotate-logs       # Rotate log files
sudo sshvpnpanel --debug             # Debug mode
sudo sshvpnpanel --version           # Show version
```

## Log Files

| Log File | Description |
|----------|-------------|
| `/var/log/sshvpnpanel/sshvpnpanel.log` | Main application log |
| `/var/log/sshvpnpanel/error.log` | Error messages only |
| `/var/log/sshvpnpanel/audit.log` | Security audit trail |
| `/var/log/sshvpnpanel/vpn_activity.log` | VPN connection events |
| `/var/log/stunnel4/stunnel4.log` | Stunnel service log |

## Troubleshooting

**Stunnel won't start:**
```bash
# Check config syntax
stunnel4 -f /etc/stunnel/stunnel.conf
# Check permissions on cert files
ls -la /etc/sshvpnpanel/certs/
```

**SSH users can't connect:**
```bash
# Verify user exists
id username
# Check account lock status
passwd -S username
# Check SSH service
systemctl status sshd
```

**Certificate expired:**
```bash
sudo sshvpnpanel --renew-certs
# or
sudo sshvpnpanel  # → TLS/SNI → Auto-Renew Expiring Certificates
```
