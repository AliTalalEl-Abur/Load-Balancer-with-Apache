#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Project: Apache Load Balancer + NFS + MySQL on AWS
# Based on the phases shown in the workspace images.
# ==========================================================
# Usage:
#   1) Adjust variables (KEY_PATH and IPs) if they change.
#   2) Run in blocks as you progress in AWS Console.
#   3) If you use Windows, run from WSL or Git Bash.
# ==========================================================

# -----------------------------
# Variables (based on screenshots)
# -----------------------------
KEY_PATH="./web-project-key.pem"

NFS_HOST="35.173.201.166"
WEB1_HOST="54.80.58.167"
WEB2_HOST="54.175.161.215"
MYSQL_HOST="54.175.214.201"
LB_HOST="3.84.123.78"

# Private IPs for mounts and load balancing
NFS_PRIVATE_IP="172.31.36.168"
WEB1_PRIVATE_IP="172.31.32.60"
WEB2_PRIVATE_IP="172.31.45.125"

# User per OS
RHEL_USER="ec2-user"
UBUNTU_USER="ubuntu"

# -----------------------------
# Helpers
# -----------------------------
ssh_rhel() {
  local host="$1"
  shift
  ssh -o StrictHostKeyChecking=accept-new -i "$KEY_PATH" "$RHEL_USER@$host" "$*"
}

ssh_ubuntu() {
  local host="$1"
  shift
  ssh -o StrictHostKeyChecking=accept-new -i "$KEY_PATH" "$UBUNTU_USER@$host" "$*"
}

# ==========================================================
# PHASE 1-4 (MANUAL AWS CONSOLE)
# ==========================================================
: '
1) Create 5 EC2 instances:
   - nfs-server (RHEL)
   - web-server-1 (RHEL)
   - web-server-2 (RHEL)
   - mysql-server (RHEL)
   - apache-lb (Ubuntu)

2) Create Security Group "project-sg" with description "Security group for web project".

3) Inbound rules observed in screenshots:
  - SSH (22/tcp) from 0.0.0.0/0
  - HTTP (80/tcp) from 0.0.0.0/0
  - MySQL/Aurora (3306/tcp) from 172.31.0.0/16
  - NFS (2049/tcp) from 172.31.0.0/16
  - TCP custom (111/tcp) from 172.31.0.0/16
  - UDP custom (111/udp) from 172.31.0.0/16

4) Attach that Security Group to the project instances.
'

# ==========================================================
# PHASE 5-10 (NFS SERVER - RHEL)
# ==========================================================
setup_nfs_server() {
  echo "[NFS] Installing packages..."
  ssh_rhel "$NFS_HOST" "sudo yum install nfs-utils nfs4-acl-tools -y"

  echo "[NFS] Creating shared directories..."
  ssh_rhel "$NFS_HOST" "sudo mkdir -p /mnt/apps /mnt/logs"

  echo "[NFS] Setting permissions..."
  ssh_rhel "$NFS_HOST" "sudo chmod -R 777 /mnt/apps && sudo chmod -R 777 /mnt/logs"

  echo "[NFS] Configuring /etc/exports..."
  ssh_rhel "$NFS_HOST" "echo '/mnt/apps 172.31.0.0/16(rw,sync,no_root_squash,no_all_squash)' | sudo tee /etc/exports >/dev/null"
  ssh_rhel "$NFS_HOST" "echo '/mnt/logs 172.31.0.0/16(rw,sync,no_root_squash,no_all_squash)' | sudo tee -a /etc/exports >/dev/null"

  echo "[NFS] Restarting and enabling service..."
  ssh_rhel "$NFS_HOST" "sudo systemctl restart nfs-server && sudo systemctl enable nfs-server"

  echo "[NFS] Exporting and verifying..."
  ssh_rhel "$NFS_HOST" "sudo exportfs -rav && sudo exportfs -v"
}

# ==========================================================
# PHASE 11-20 (WEB SERVERS - RHEL)
# ==========================================================
setup_web_server() {
  local host="$1"

  echo "[WEB $host] Installing NFS client..."
  ssh_rhel "$host" "sudo yum install nfs-utils nfs4-acl-tools -y"

  echo "[WEB $host] Installing Apache, PHP, and Git..."
  ssh_rhel "$host" "sudo yum install httpd php php-mysqlnd php-fpm git -y"

  echo "[WEB $host] Starting and enabling Apache/PHP-FPM..."
  ssh_rhel "$host" "sudo systemctl start httpd && sudo systemctl enable httpd"
  ssh_rhel "$host" "sudo systemctl start php-fpm && sudo systemctl enable php-fpm"

  echo "[WEB $host] Mounting NFS on /var/www/html..."
  ssh_rhel "$host" "sudo mkdir -p /var/www/html"
  ssh_rhel "$host" "sudo mount -t nfs -o rw,nosuid ${NFS_PRIVATE_IP}:/mnt/apps /var/www/html"

  echo "[WEB $host] Making mount persistent in /etc/fstab..."
  ssh_rhel "$host" "grep -q '${NFS_PRIVATE_IP}:/mnt/apps /var/www/html nfs defaults 0 0' /etc/fstab || echo '${NFS_PRIVATE_IP}:/mnt/apps /var/www/html nfs defaults 0 0' | sudo tee -a /etc/fstab"

  echo "[WEB $host] Cloning project and copying content..."
  ssh_rhel "$host" "cd /var/www/html && sudo rm -rf tooling && sudo git clone https://github.com/darey-devops/tooling.git"
  ssh_rhel "$host" "sudo cp -R /var/www/html/tooling/html/* /var/www/html/"

  echo "[WEB $host] Setting Apache permissions..."
  ssh_rhel "$host" "sudo chown -R apache:apache /var/www/html && sudo chmod -R 755 /var/www/html"

  echo "[WEB $host] Verifying services and port 80..."
  ssh_rhel "$host" "sudo systemctl status httpd --no-pager"
  ssh_rhel "$host" "sudo systemctl status php-fpm --no-pager"
  ssh_rhel "$host" "sudo ss -tulpn | grep :80 || true"
}

# ==========================================================
# PHASE 21-24 (MYSQL SERVER - RHEL)
# ==========================================================
setup_mysql_server() {
  echo "[MYSQL] Installing MySQL server..."
  ssh_rhel "$MYSQL_HOST" "sudo yum install mysql-server -y"

  echo "[MYSQL] Starting and enabling mysqld..."
  ssh_rhel "$MYSQL_HOST" "sudo systemctl start mysqld && sudo systemctl enable mysqld"

  echo "[MYSQL] Creating DB and webaccess user..."
  ssh_rhel "$MYSQL_HOST" "mysql -u root <<'SQL'
CREATE DATABASE IF NOT EXISTS tooling;
CREATE USER IF NOT EXISTS 'webaccess'@'%' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON tooling.* TO 'webaccess'@'%';
FLUSH PRIVILEGES;
SELECT user, host FROM mysql.user;
SQL"
}

# ==========================================================
# PHASE 25-31 (APACHE LOAD BALANCER - UBUNTU)
# ==========================================================
setup_load_balancer() {
  echo "[LB] Updating repos and installing apache2..."
  ssh_ubuntu "$LB_HOST" "sudo apt update -y && sudo apt install apache2 -y"

  echo "[LB] Enabling proxy and load-balancer modules..."
  ssh_ubuntu "$LB_HOST" "sudo a2enmod rewrite proxy proxy_balancer proxy_http headers lbmethod_bytraffic"

  echo "[LB] Configuring load-balancer virtual host..."
  ssh_ubuntu "$LB_HOST" "sudo tee /etc/apache2/sites-available/000-default.conf >/dev/null <<'CONF'
<VirtualHost *:80>
    <Proxy \"balancer://mycluster\">
        BalancerMember http://${WEB1_PRIVATE_IP}:80 loadfactor=5
        BalancerMember http://${WEB2_PRIVATE_IP}:80 loadfactor=5
        ProxySet lbmethod=bytraffic
    </Proxy>

    ProxyPreserveHost On
    ProxyPass / balancer://mycluster/
    ProxyPassReverse / balancer://mycluster/
</VirtualHost>
CONF"

  echo "[LB] Restarting apache2 and checking status..."
  ssh_ubuntu "$LB_HOST" "sudo systemctl restart apache2 && sudo systemctl status apache2 --no-pager"
}

# ==========================================================
# EXECUTION
# ==========================================================
# Uncomment based on what you want to run.

# setup_nfs_server
# setup_web_server "$WEB1_HOST"
# setup_web_server "$WEB2_HOST"
# setup_mysql_server
# setup_load_balancer

# Example to run everything in order:
# setup_nfs_server
# setup_web_server "$WEB1_HOST"
# setup_web_server "$WEB2_HOST"
# setup_mysql_server
# setup_load_balancer


echo "Script generated. Review variables and uncomment blocks in the EXECUTION section."
