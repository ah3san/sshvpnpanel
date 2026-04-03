# Installation Guide

## Prerequisites

- Linux server running Ubuntu 18.04+, Debian 10+, CentOS 7+, RHEL 7+, or Alpine Linux 3.12+
- Root or sudo access
- Bash 4.0+
- Internet connection (for package installation)

## Quick Installation

```bash
git clone https://github.com/ah3san/sshvpnpanel.git
cd sshvpnpanel
sudo bash installer.sh
```

## Installation Options

```bash
# Custom installation directory
sudo bash installer.sh --install-dir /opt/sshvpnpanel

# Custom ports
sudo bash installer.sh --port 2222 --ssl-port 8443

# Non-interactive (uses defaults)
sudo bash installer.sh --no-interactive

# Show all options
bash installer.sh --help
```

## Manual Installation

If the automated installer doesn't work for your system:

### 1. Install Dependencies

**Ubuntu/Debian:**
```bash
apt-get update
apt-get install -y openssh-server stunnel4 openssl curl wget \
                   net-tools iproute2 iptables fail2ban
```

**CentOS/RHEL:**
```bash
yum install -y openssh-server stunnel openssl curl wget \
               net-tools iproute iptables fail2ban
```

**Alpine Linux:**
```bash
apk add openssh stunnel openssl curl wget net-tools iproute2 iptables
```

### 2. Create Directories

```bash
mkdir -p /opt/sshvpnpanel/modules
mkdir -p /etc/sshvpnpanel/{certs/ca,stunnel/tunnels,sni,admins,users}
mkdir -p /var/log/sshvpnpanel
mkdir -p /var/backups/sshvpnpanel
```

### 3. Copy Files

```bash
cp sshvpnpanel.sh installer.sh /opt/sshvpnpanel/
cp modules/*.sh /opt/sshvpnpanel/modules/
cp config/*.conf /etc/sshvpnpanel/
chmod 750 /opt/sshvpnpanel/sshvpnpanel.sh
ln -s /opt/sshvpnpanel/sshvpnpanel.sh /usr/local/bin/sshvpnpanel
```

### 4. Initial Configuration

```bash
# Set admin password
echo -n "your_password" | sha256sum | awk '{print $1}'
# Update ADMIN_PASSWORD_HASH in /etc/sshvpnpanel/sshvpnpanel.conf
```

### 5. Generate SSL Certificate

```bash
openssl req -x509 -newkey rsa:4096 \
  -keyout /etc/sshvpnpanel/certs/stunnel.key \
  -out /etc/sshvpnpanel/certs/stunnel.crt \
  -days 365 -nodes \
  -subj "/CN=$(hostname)/O=SSH VPN Panel/C=US"
```

## Post-Installation

1. Start the panel: `sudo sshvpnpanel`
2. Login with username `admin` and the password you set
3. Change the default password immediately
4. Configure your first SSH user under **SSH User Management**
5. Set up a Stunnel tunnel under **Stunnel Management**
6. Configure the firewall under **Security Management**

## Uninstallation

```bash
sudo bash installer.sh --uninstall
```

## Upgrading

```bash
cd sshvpnpanel
git pull
sudo bash installer.sh --upgrade
```
