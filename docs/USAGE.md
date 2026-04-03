# Usage Guide

## Interactive Menu

Launch the full interactive menu:

```bash
sudo sshvpnpanel
```

Navigate using the number keys.

---

## Command-Line Interface

### User Management

#### Add a single user (interactive prompts)
```bash
sudo sshvpnpanel user add
```

#### Add a user with a specific username (interactive prompts for other options)
```bash
sudo sshvpnpanel user add alice
```

#### Add a user with all options via environment variables
```bash
sudo EXPIRE_DAYS=30 \
     QUOTA_MB=2048 \
     BANDWIDTH_LIMIT_MB=20480 \
     MAX_CONNECTIONS=2 \
     STUNNEL_DOMAIN=myvpn.example.com \
     USER_EMAIL=alice@example.com \
     SEND_WELCOME_EMAIL=true \
     sshvpnpanel user add alice secretpass
```

#### Remove a user (interactive confirm)
```bash
sudo sshvpnpanel user remove alice
```

#### Remove a user and delete all data (no archive)
```bash
sudo PRESERVE_DATA=false sshvpnpanel user remove alice
```

#### List all users
```bash
sudo sshvpnpanel user list
```

#### Show detailed user information
```bash
sudo sshvpnpanel user info alice
```

#### Suspend a user (locks account, kills sessions)
```bash
sudo sshvpnpanel user suspend alice
```

#### Reactivate a suspended user
```bash
sudo sshvpnpanel user reactivate alice
```

#### Create a trial/temporary user (7-day default)
```bash
sudo sshvpnpanel user trial trialuser 7
```

---

### Batch Operations

#### Add users from a CSV file
CSV format: `username,password,expire_days,quota_mb,bandwidth_mb,max_conn,email`

```bash
# Create a CSV file
cat > /tmp/users.csv << EOF
username,password,expire_days,quota_mb,bandwidth_mb,max_conn,email
alice,password123,30,1024,10240,2,alice@example.com
bob,password456,14,512,5120,1,bob@example.com
carol,,7,256,2048,1,
EOF

sudo sshvpnpanel batch add csv /tmp/users.csv
```

#### Add users from a JSON file
Requires `jq` to be installed.

```bash
cat > /tmp/users.json << EOF
[
  {"username": "dave", "password": "pass123", "expire_days": 30, "quota_mb": 1024},
  {"username": "eve",  "password": "pass456", "expire_days": 14, "quota_mb": 512, "email": "eve@example.com"}
]
EOF

sudo sshvpnpanel batch add json /tmp/users.json
```

#### Remove users from a list file (one username per line)
```bash
cat > /tmp/remove.txt << EOF
alice
bob
EOF

sudo sshvpnpanel batch remove /tmp/remove.txt
```

---

### Export

#### Export user list to CSV
```bash
sudo sshvpnpanel export csv /tmp/userlist.csv
```

---

### SSH Key Management

```bash
# Generate SSH key pair for a user
sudo sshvpnpanel ssh keys generate alice

# Revoke SSH keys for a user
sudo sshvpnpanel ssh keys revoke alice

# List SSH users
sudo sshvpnpanel ssh list

# Show SSH user info
sudo sshvpnpanel ssh info alice
```

---

### Stunnel Management

```bash
# List all Stunnel configurations
sudo sshvpnpanel stunnel list

# Show Stunnel info for a user
sudo sshvpnpanel stunnel info alice

# Add Stunnel configuration for a user
sudo sshvpnpanel stunnel add alice

# Add with specific port and domain
sudo sshvpnpanel stunnel add alice 8443 myvpn.example.com

# Remove Stunnel configuration for a user
sudo sshvpnpanel stunnel remove alice
```

---

### TLS/SNI Management

```bash
# Initialize the internal CA (run once)
sudo sshvpnpanel tls init-ca

# Issue a TLS certificate for a user
sudo sshvpnpanel tls issue alice myvpn.example.com

# Issue with custom validity (days)
sudo sshvpnpanel tls issue alice myvpn.example.com 90

# Revoke a user's TLS certificate
sudo sshvpnpanel tls revoke alice

# Add an SNI domain for a user
sudo sshvpnpanel sni add alice myvpn.example.com

# Remove an SNI domain
sudo sshvpnpanel sni remove alice myvpn.example.com

# List all SNI domains for a user
sudo sshvpnpanel sni list alice
```

---

### Firewall Management

```bash
# Apply default firewall rules
sudo sshvpnpanel firewall defaults

# List whitelisted users
sudo sshvpnpanel firewall list

# Add a user to the whitelist (any IP)
sudo sshvpnpanel firewall add alice

# Add a user with a specific allowed IP
sudo sshvpnpanel firewall add alice 203.0.113.50

# Remove a user from the whitelist
sudo sshvpnpanel firewall remove alice
```

---

### VPN Profiles

```bash
# List all VPN users
sudo sshvpnpanel vpn list

# Show VPN profile for a user
sudo sshvpnpanel vpn info alice
```

---

### Monitoring

```bash
# Show full system dashboard
sudo sshvpnpanel monitor

# Show bandwidth stats for a user
sudo sshvpnpanel monitor bandwidth alice

# Show connection history for a user
sudo sshvpnpanel monitor history alice

# Show service status
sudo sshvpnpanel monitor status
```

---

## User Templates

You can create reusable user templates in `/etc/sshvpnpanel/templates/`.
Copy `user_template.conf` as a starting point:

```bash
sudo cp /etc/sshvpnpanel/templates/default.conf /etc/sshvpnpanel/templates/premium.conf
sudo nano /etc/sshvpnpanel/templates/premium.conf
```

Use a template when adding a user:
```bash
sudo TEMPLATE_FILE=/etc/sshvpnpanel/templates/premium.conf sshvpnpanel user add alice
```

---

## Audit Logs

All user actions are recorded in `/var/log/sshvpnpanel/audit.log`:

```bash
sudo tail -f /var/log/sshvpnpanel/audit.log
```

Log format:
```
[TIMESTAMP] [LEVEL] [function:line] message
[TIMESTAMP] AUDIT | action=USER_ADDED | user=alice | operator=root | expire=2024-02-01 ...
```
