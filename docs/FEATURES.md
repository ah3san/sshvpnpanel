# Feature List

## User Add Features

| Feature | Description |
|---|---|
| SSH system account creation | Creates a Linux system account with home directory and shell |
| Auto password generation | Generates a strong random password if none is provided |
| SSH key pair generation | Generates ed25519 or RSA key pairs and adds to authorized_keys |
| Session limits | Configures `MaxSessions` in sshd_config per user |
| Stunnel tunnel provisioning | Auto-assigns a free port and creates a per-user Stunnel TLS tunnel |
| SNI domain assignment | Associates an SNI domain with the user for TLS routing |
| TLS certificate issuance | Issues a CA-signed TLS certificate for the user's domain |
| Firewall whitelist entry | Adds user to the IP whitelist (with optional IP restriction) |
| Rate limiting | Applies per-user SSH connection rate limiting via iptables |
| Fail2ban jail | Creates a fail2ban jail to protect against brute-force attacks |
| VPN profile creation | Creates a VPN user profile with quota, bandwidth limit, and expiry |
| Bandwidth monitoring setup | Creates per-user bandwidth tracking log |
| Logging setup | Sets up per-user rsyslog filter for activity logging |
| User directory setup | Creates `~/vpn` and `~/.config/sshvpnpanel` directories |
| Welcome email | Optionally sends credentials and connection info via email |
| User template support | Load pre-configured settings from a template file |
| Expiry date setting | Sets account expiry via `chage` |
| Disk quota | Applies disk quota via `setquota` if available |
| Audit logging | Records the creation event with all parameters |

## User Remove Features

| Feature | Description |
|---|---|
| Session termination | Kills all active sessions (SIGTERM then SIGKILL) |
| SSH account removal | Deletes the system user account (optionally preserving home dir) |
| SSH key revocation | Removes authorized_keys and key files |
| SSH config cleanup | Removes the `Match User` block from sshd_config |
| Stunnel tunnel removal | Removes per-user Stunnel config and reloads Stunnel |
| TLS certificate revocation | Revokes cert with CA and removes cert files |
| SNI domain removal | Removes all SNI domain assignments |
| Firewall rule removal | Removes whitelist entry and iptables rules |
| Rate limit removal | Removes per-user rate-limiting iptables chain |
| Fail2ban jail removal | Removes fail2ban jail configuration |
| VPN profile removal | Removes VPN profile and usage statistics |
| Monitoring teardown | Archives bandwidth log, removes rsyslog filter |
| Home directory archiving | Tarballs home directory to archive location |
| Panel data cleanup | Removes per-user data from `/var/lib/sshvpnpanel/users/` |
| Removal notification email | Optionally sends removal notification email |
| Final audit report | Generates a text audit report with full activity history |
| Audit logging | Records the removal event |

## Batch Operations

| Feature | Description |
|---|---|
| CSV import | Add multiple users from a comma-separated values file |
| JSON import | Add multiple users from a JSON array file (requires `jq`) |
| Batch remove | Remove multiple users from a plain text list |
| Per-operation results | Reports success/failure counts after batch operations |

## User Lifecycle Management

| Feature | Description |
|---|---|
| User suspension | Locks account, kills sessions, blocks firewall, sets VPN status |
| User reactivation | Unlocks account, removes block rules, restores VPN status |
| Trial user creation | Creates temporary accounts with reduced quotas |
| User information display | Shows SSH, Stunnel, TLS, VPN, and bandwidth info in one view |
| CSV export | Exports full user list with all service metadata |

## Service Integration

| Service | Integration |
|---|---|
| SSH (sshd) | Account creation, key management, session limits, config management |
| Stunnel 4 | Per-user TLS tunnel with automatic port allocation, SNI support |
| OpenSSL | TLS certificate issuance, internal CA management |
| iptables / ufw | Per-user allow rules, rate limiting chains |
| fail2ban | Per-user jail configuration |
| VPN profiles | Custom profile system with quota and bandwidth tracking |
| Bandwidth monitoring | Per-user log files with inbound/outbound byte tracking |
| rsyslog | Per-user activity log filtering |
| setquota | Disk quota management (when quota tools are available) |
| Email (sendmail/mail) | Welcome and removal notification emails |

## System Monitoring

| Feature | Description |
|---|---|
| System dashboard | CPU, memory, disk, load average, uptime overview |
| Service status | Real-time status of SSH, Stunnel, fail2ban, ufw/iptables |
| Active sessions | Current SSH sessions via `who` |
| Bandwidth report | Per-user inbound/outbound statistics |
| Connection history | Per-user connection history from auth.log |
| Audit log viewer | Recent audit events in dashboard |

## Security Features

| Feature | Description |
|---|---|
| SSH hardening | Applies best-practice sshd_config settings |
| Default firewall rules | DROP-by-default INPUT policy with selective allows |
| Rate limiting | Limits SSH connection attempts per minute |
| Fail2ban integration | Auto-bans IPs after repeated authentication failures |
| TLS 1.2+ enforcement | Stunnel configured to reject SSLv2/v3/TLS1.0/1.1 |
| Per-user TLS certificates | Each user gets a unique certificate with SAN |
| Audit trail | Every action is recorded with timestamp, user, and operator |
| Data archival | Removed user data is preserved for compliance |

## Configuration

| File | Purpose |
|---|---|
| `/etc/sshvpnpanel/sshvpnpanel.conf` | Main panel configuration |
| `/etc/sshvpnpanel/security.conf` | Security-specific settings |
| `/etc/sshvpnpanel/templates/default.conf` | Default user template |
| `/etc/stunnel/users/*.conf` | Per-user Stunnel configurations |
| `/etc/ssl/sshvpnpanel/` | CA and user TLS certificates |
| `/var/log/sshvpnpanel/audit.log` | Audit log |
| `/var/lib/sshvpnpanel/users/` | Per-user runtime data |
| `/var/backups/sshvpnpanel/archived_users/` | Archived user data |
