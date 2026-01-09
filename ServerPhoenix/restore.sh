#!/bin/bash
# ServerPhoenix - Restore Script
# Restores full backup to a new server
# Downloads from GitHub and runs automatically - no pre-installation needed
#
# Usage: restore.sh <backup-file.tar.gz> [username]
# Example: restore.sh /tmp/full-server-backup.tar.gz speedo

set -e

BACKUP_FILE="$1"
DEST_USER="${2:-$(whoami)}"
DEST_HOME="/home/$DEST_USER"

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup-file.tar.gz> [username]"
    echo "Example: $0 /tmp/full-server-backup.tar.gz speedo"
    exit 1
fi

RESTORE_DIR="/tmp/restore-$$"
mkdir -p "$RESTORE_DIR"

echo "=========================================="
echo "ServerPhoenix - Server Restore"
echo "=========================================="
echo "Backup: $BACKUP_FILE"
echo "User: $DEST_USER"
echo "=========================================="

# ============================================
# EXTRACT BACKUP
# ============================================
echo ""
echo "[1/12] Extracting backup..."
tar xzf "$BACKUP_FILE" -C "$RESTORE_DIR"

# Show what we're restoring
if [ -f "$RESTORE_DIR/metadata.json" ]; then
    echo "  - Source: $(jq -r '.source_hostname // "unknown"' "$RESTORE_DIR/metadata.json")"
    echo "  - Date: $(jq -r '.backup_date // "unknown"' "$RESTORE_DIR/metadata.json")"
fi

# ============================================
# INSTALL BASE PACKAGES
# ============================================
echo ""
echo "[2/12] Installing base packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq curl wget git jq

# ============================================
# ANALYZE AND INSTALL REQUIREMENTS
# ============================================
echo ""
echo "[3/12] Analyzing backup and installing required software..."

# Node.js + PM2
if [ -f "$RESTORE_DIR/apps/pm2-processes.json" ] && [ -s "$RESTORE_DIR/apps/pm2-processes.json" ]; then
    process_count=$(jq '. | length' "$RESTORE_DIR/apps/pm2-processes.json" 2>/dev/null || echo 0)
    if [ "$process_count" -gt 0 ]; then
        echo "  - Found $process_count PM2 processes, installing Node.js..."
        if ! command -v node &>/dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1
            sudo apt-get install -y -qq nodejs
        fi
        sudo npm install -g pm2 >/dev/null 2>&1
        echo "    - Node.js $(node --version 2>/dev/null || echo 'installed')"
        echo "    - PM2 $(pm2 --version 2>/dev/null || echo 'installed')"
    fi
fi

# Python
python_needed=false
if ls "$RESTORE_DIR"/apps/home-*.tar.gz 2>/dev/null | xargs -I {} tar tzf {} 2>/dev/null | grep -q "requirements.txt"; then
    python_needed=true
fi
if ls "$RESTORE_DIR"/apps/home-*.tar.gz 2>/dev/null | xargs -I {} tar tzf {} 2>/dev/null | grep -q "/venv/"; then
    python_needed=true
fi
if [ "$python_needed" = true ]; then
    echo "  - Found Python apps, installing Python..."
    sudo apt-get install -y -qq python3 python3-pip python3-venv
    echo "    - Python $(python3 --version 2>/dev/null || echo 'installed')"
fi

# Docker
if [ -d "$RESTORE_DIR/docker" ] && [ "$(ls -A "$RESTORE_DIR/docker" 2>/dev/null)" ]; then
    echo "  - Found Docker data, installing Docker..."
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        sudo usermod -aG docker "$DEST_USER"
    fi
    echo "    - Docker $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo 'installed')"
fi

# Nginx
if [ -f "$RESTORE_DIR/configs/nginx.tar.gz" ]; then
    echo "  - Found Nginx configs, installing Nginx..."
    sudo apt-get install -y -qq nginx
    echo "    - Nginx installed"
fi

# Apache
if [ -f "$RESTORE_DIR/configs/apache.tar.gz" ]; then
    echo "  - Found Apache configs, installing Apache..."
    sudo apt-get install -y -qq apache2
    echo "    - Apache installed"
fi

# ============================================
# RESTORE HOME DIRECTORIES
# ============================================
echo ""
echo "[4/12] Restoring user home directories..."
for home_backup in "$RESTORE_DIR"/apps/home-*.tar.gz; do
    [ -f "$home_backup" ] || continue
    backup_user=$(basename "$home_backup" .tar.gz | sed 's/home-//')
    echo "  - User: $backup_user"

    # Create user if doesn't exist
    if ! id "$backup_user" &>/dev/null; then
        echo "    - Creating user $backup_user..."
        sudo useradd -m -s /bin/bash "$backup_user" 2>/dev/null || true
    fi

    sudo tar xzf "$home_backup" -C / 2>/dev/null || true
    sudo chown -R "$backup_user:$backup_user" "/home/$backup_user" 2>/dev/null || true
done

# ============================================
# RESTORE NGINX
# ============================================
echo ""
echo "[5/12] Restoring Nginx..."
if [ -f "$RESTORE_DIR/configs/nginx.tar.gz" ]; then
    echo "  - Restoring nginx configs..."
    sudo tar xzf "$RESTORE_DIR/configs/nginx.tar.gz" -C / 2>/dev/null || true

    # Restore document roots
    for root_backup in "$RESTORE_DIR"/apps/nginx-root*.tar.gz; do
        [ -f "$root_backup" ] || continue
        echo "  - Document root: $(basename "$root_backup")"
        sudo tar xzf "$root_backup" -C / 2>/dev/null || true
    done

    # Test and reload
    if sudo nginx -t 2>/dev/null; then
        sudo systemctl enable nginx 2>/dev/null || true
        sudo systemctl reload nginx 2>/dev/null || sudo systemctl start nginx 2>/dev/null || true
        echo "  - Nginx configured and running"
    else
        echo "  - WARNING: Nginx config test failed (may need SSL certs)"
    fi
else
    echo "  - No Nginx config to restore"
fi

# ============================================
# RESTORE APACHE
# ============================================
echo ""
echo "[6/12] Restoring Apache..."
if [ -f "$RESTORE_DIR/configs/apache.tar.gz" ]; then
    echo "  - Restoring apache configs..."
    sudo tar xzf "$RESTORE_DIR/configs/apache.tar.gz" -C / 2>/dev/null || true

    # Restore document roots
    for root_backup in "$RESTORE_DIR"/apps/apache-root*.tar.gz; do
        [ -f "$root_backup" ] || continue
        echo "  - Document root: $(basename "$root_backup")"
        sudo tar xzf "$root_backup" -C / 2>/dev/null || true
    done

    # Test and reload
    if sudo apache2ctl configtest 2>/dev/null; then
        sudo systemctl enable apache2 2>/dev/null || true
        sudo systemctl reload apache2 2>/dev/null || sudo systemctl start apache2 2>/dev/null || true
        echo "  - Apache configured and running"
    else
        echo "  - WARNING: Apache config test failed"
    fi
else
    echo "  - No Apache config to restore"
fi

# ============================================
# RESTORE SYSTEMD SERVICES
# ============================================
echo ""
echo "[7/12] Restoring systemd services..."
if [ -d "$RESTORE_DIR/system/systemd" ] && [ "$(ls -A "$RESTORE_DIR/system/systemd" 2>/dev/null)" ]; then
    # First restore the app directories that services depend on
    for app_backup in "$RESTORE_DIR"/apps/systemd-*.tar.gz; do
        [ -f "$app_backup" ] || continue
        echo "  - App directory: $(basename "$app_backup")"
        sudo tar xzf "$app_backup" -C / 2>/dev/null || true
    done

    # Then copy service files
    for service_file in "$RESTORE_DIR"/system/systemd/*.service; do
        [ -f "$service_file" ] || continue
        service_name=$(basename "$service_file")
        echo "  - Service: $service_name"
        sudo cp "$service_file" /etc/systemd/system/ 2>/dev/null || true
    done

    sudo systemctl daemon-reload
else
    echo "  - No custom services to restore"
fi

# ============================================
# RESTORE DATABASES
# ============================================
echo ""
echo "[8/12] Restoring databases..."

# MySQL
mysql_restored=false
for sql in "$RESTORE_DIR"/databases/mysql-*.sql; do
    [ -f "$sql" ] || continue

    if [ "$mysql_restored" = false ]; then
        echo "  - Installing MySQL server..."
        sudo apt-get install -y -qq mysql-server 2>/dev/null || true
        sudo systemctl start mysql 2>/dev/null || true
        mysql_restored=true
    fi

    db=$(basename "$sql" .sql | sed 's/mysql-//')
    echo "  - MySQL database: $db"
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\`" 2>/dev/null || true
    mysql "$db" < "$sql" 2>/dev/null || true
done

# PostgreSQL
postgres_restored=false
for sql in "$RESTORE_DIR"/databases/postgres-*.sql; do
    [ -f "$sql" ] || continue

    if [ "$postgres_restored" = false ]; then
        echo "  - Installing PostgreSQL server..."
        sudo apt-get install -y -qq postgresql 2>/dev/null || true
        sudo systemctl start postgresql 2>/dev/null || true
        postgres_restored=true
    fi

    db=$(basename "$sql" .sql | sed 's/postgres-//')
    echo "  - PostgreSQL database: $db"
    sudo -u postgres createdb "$db" 2>/dev/null || true
    sudo -u postgres psql "$db" < "$sql" 2>/dev/null || true
done

# MongoDB
if [ -d "$RESTORE_DIR/databases/mongodb" ]; then
    echo "  - Installing MongoDB..."
    # Try different methods for MongoDB installation
    if ! command -v mongod &>/dev/null; then
        # Ubuntu/Debian
        curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor 2>/dev/null || true
        echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list >/dev/null 2>&1 || true
        sudo apt-get update -qq 2>/dev/null || true
        sudo apt-get install -y -qq mongodb-org 2>/dev/null || sudo apt-get install -y -qq mongodb 2>/dev/null || true
    fi
    sudo systemctl start mongod 2>/dev/null || true
    echo "  - Restoring MongoDB databases..."
    mongorestore "$RESTORE_DIR/databases/mongodb" 2>/dev/null || true
fi

# Redis
if [ -f "$RESTORE_DIR/databases/dump.rdb" ]; then
    echo "  - Installing Redis..."
    sudo apt-get install -y -qq redis-server
    sudo systemctl stop redis-server 2>/dev/null || sudo systemctl stop redis 2>/dev/null || true
    sudo cp "$RESTORE_DIR/databases/dump.rdb" /var/lib/redis/
    sudo chown redis:redis /var/lib/redis/dump.rdb
    sudo systemctl start redis-server 2>/dev/null || sudo systemctl start redis 2>/dev/null || true
    echo "  - Redis restored"
fi

# ============================================
# RESTORE DOCKER
# ============================================
echo ""
echo "[9/12] Restoring Docker..."
if [ -d "$RESTORE_DIR/docker" ] && [ "$(ls -A "$RESTORE_DIR/docker" 2>/dev/null)" ]; then
    # Restore volumes
    for vol_backup in "$RESTORE_DIR"/docker/volume-*.tar.gz; do
        [ -f "$vol_backup" ] || continue
        vol_name=$(basename "$vol_backup" .tar.gz | sed 's/volume-//')
        echo "  - Volume: $vol_name"
        docker volume create "$vol_name" 2>/dev/null || true
        docker run --rm -v "$vol_name":/data -v "$RESTORE_DIR/docker":/backup alpine \
            tar xzf "/backup/$(basename "$vol_backup")" -C /data 2>/dev/null || true
    done

    # Find and start docker-compose projects
    echo "  - Looking for docker-compose projects..."
    for compose in "$RESTORE_DIR"/docker/*docker-compose*.yml "$RESTORE_DIR"/docker/*compose.yml; do
        [ -f "$compose" ] || continue
        compose_name=$(basename "$compose")
        # Try to find where this compose file should be
        original_path=$(echo "$compose_name" | tr '_' '/' | sed 's|^|/|')
        original_dir=$(dirname "$original_path")

        if [ -d "$original_dir" ]; then
            echo "  - Starting compose in: $original_dir"
            (cd "$original_dir" && docker compose up -d 2>/dev/null) || true
        fi
    done
else
    echo "  - No Docker data to restore"
fi

# ============================================
# RESTORE PM2 APPS
# ============================================
echo ""
echo "[10/12] Restoring PM2 processes..."
if [ -f "$RESTORE_DIR/apps/pm2-processes.json" ]; then
    process_count=$(jq '. | length' "$RESTORE_DIR/apps/pm2-processes.json" 2>/dev/null || echo 0)

    if [ "$process_count" -gt 0 ]; then
        # Restore PM2 app directories
        for app_backup in "$RESTORE_DIR"/apps/pm2-*.tar.gz; do
            [ -f "$app_backup" ] || continue
            app_name=$(basename "$app_backup" .tar.gz | sed 's/pm2-//')
            echo "  - App: $app_name"
            tar xzf "$app_backup" -C "$DEST_HOME/" 2>/dev/null || true
        done

        # Install dependencies for each app
        for app_path in $(jq -r '.[].pm2_env.pm_cwd // empty' "$RESTORE_DIR/apps/pm2-processes.json" 2>/dev/null); do
            if [ -d "$app_path" ]; then
                app_name=$(basename "$app_path")
                echo "  - Installing dependencies: $app_name"

                # Fix ownership
                sudo chown -R "$DEST_USER:$DEST_USER" "$app_path" 2>/dev/null || true

                # Install npm dependencies
                if [ -f "$app_path/package.json" ]; then
                    (cd "$app_path" && npm install --production 2>/dev/null) || true
                fi

                # Install pip dependencies
                if [ -f "$app_path/requirements.txt" ]; then
                    if [ -d "$app_path/venv" ]; then
                        (cd "$app_path" && source venv/bin/activate && pip install -r requirements.txt 2>/dev/null) || true
                    else
                        (cd "$app_path" && pip3 install -r requirements.txt 2>/dev/null) || true
                    fi
                fi
            fi
        done

        # Restore PM2 process list
        if [ -f "$RESTORE_DIR/apps/dump.pm2" ]; then
            mkdir -p ~/.pm2
            cp "$RESTORE_DIR/apps/dump.pm2" ~/.pm2/
            echo "  - Resurrecting PM2 processes..."
            pm2 resurrect 2>/dev/null || true
            pm2 save 2>/dev/null || true
        fi
    fi
else
    echo "  - No PM2 processes to restore"
fi

# ============================================
# RESTORE CRONTABS
# ============================================
echo ""
echo "[11/12] Restoring crontabs..."
for cron_file in "$RESTORE_DIR"/system/crontab-*; do
    [ -f "$cron_file" ] || continue
    [ -s "$cron_file" ] || continue

    user=$(basename "$cron_file" | sed 's/crontab-//')
    [ "$user" = "system" ] && continue

    echo "  - Crontab for: $user"
    crontab -u "$user" "$cron_file" 2>/dev/null || true
done

# ============================================
# START ALL SERVICES
# ============================================
echo ""
echo "[12/12] Starting all services..."

# Enable and start nginx
sudo systemctl enable nginx 2>/dev/null || true
sudo systemctl start nginx 2>/dev/null || true

# Start custom systemd services
for service in /etc/systemd/system/*.service; do
    [ -f "$service" ] || continue
    name=$(basename "$service" .service)

    # Skip system services
    [[ "$name" =~ ^(snap|cloud|ssh|systemd|getty|user@|dbus) ]] && continue

    echo "  - Starting: $name"
    sudo systemctl enable "$name" 2>/dev/null || true
    sudo systemctl start "$name" 2>/dev/null || true
done

# ============================================
# CLEANUP
# ============================================
rm -rf "$RESTORE_DIR"

# ============================================
# SUMMARY
# ============================================
echo ""
echo "=========================================="
echo "ServerPhoenix - Restore Complete!"
echo "=========================================="
echo ""
echo "Services Status:"
echo "----------------"
systemctl list-units --type=service --state=running --no-pager 2>/dev/null | grep -E "nginx|apache|mysql|postgresql|mongod|redis|pm2" | head -10 || true
echo ""
echo "Listening Ports:"
echo "----------------"
ss -tlnp 2>/dev/null | grep -E "LISTEN" | head -15 || true
echo ""
echo "=========================================="
echo "NEXT STEPS:"
echo "=========================================="
echo ""
echo "1. Update DNS records to point to this server's IP:"
echo "   - Your domains need to resolve to: $(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""
echo "2. Install SSL certificates:"
echo "   sudo apt install certbot python3-certbot-nginx"
echo "   sudo certbot --nginx"
echo ""
echo "3. Verify all services:"
echo "   systemctl list-units --type=service --state=running"
echo "   pm2 status"
echo ""
echo "4. Test your applications!"
echo ""
echo "=========================================="
