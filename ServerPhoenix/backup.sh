#!/bin/bash
# ServerPhoenix - Backup Script
# Creates comprehensive backup of everything detected by scanner
# Downloads from GitHub and runs automatically - no pre-installation needed
#
# Usage: backup.sh [inventory_file] [username]
# Default: Uses /tmp/server-inventory.json and current user

set -e

INVENTORY="${1:-/tmp/server-inventory.json}"
BACKUP_USER="${2:-$(whoami)}"
BACKUP_DIR="/tmp/server-backup-$(date +%Y%m%d-%H%M%S)"
FINAL_BACKUP="/tmp/full-server-backup.tar.gz"

echo "=========================================="
echo "ServerPhoenix - Full Server Backup"
echo "=========================================="
echo "User: $BACKUP_USER"
echo "Inventory: $INVENTORY"
echo "=========================================="

# Create backup directory structure
mkdir -p "$BACKUP_DIR"/{apps,configs,databases,docker,system}

# ============================================
# 1. DOCKER BACKUP
# ============================================
echo ""
echo "[1/10] Docker..."
if command -v docker &>/dev/null && [ -n "$(docker ps -q 2>/dev/null)" ]; then
    echo "  - Backing up container info..."
    docker ps -a --format '{{.Names}} {{.Image}} {{.Ports}} {{.Status}}' > "$BACKUP_DIR/docker/containers.txt" 2>/dev/null || true

    # Export Docker images (optional - can be large)
    # docker images --format '{{.Repository}}:{{.Tag}}' > "$BACKUP_DIR/docker/images.txt" 2>/dev/null || true

    # Backup volumes
    for vol in $(docker volume ls -q 2>/dev/null); do
        echo "  - Volume: $vol"
        docker run --rm -v "$vol":/data -v "$BACKUP_DIR/docker":/backup alpine \
            tar czf "/backup/volume-$vol.tar.gz" -C /data . 2>/dev/null || true
    done

    # Copy compose files
    find /home /opt /srv -name "docker-compose*.yml" -o -name "compose.yml" 2>/dev/null | while read f; do
        if [ -f "$f" ]; then
            # Copy with directory structure preserved
            rel_path=$(echo "$f" | sed 's|^/||' | tr '/' '_')
            cp "$f" "$BACKUP_DIR/docker/$rel_path" 2>/dev/null || true
            echo "  - Compose: $f"
        fi
    done
else
    echo "  - Docker not found or no containers running"
fi

# ============================================
# 2. PM2 BACKUP
# ============================================
echo ""
echo "[2/10] PM2..."
if command -v pm2 &>/dev/null; then
    echo "  - Saving PM2 process list..."
    pm2 save 2>/dev/null || true
    cp ~/.pm2/dump.pm2 "$BACKUP_DIR/apps/" 2>/dev/null || true
    pm2 jlist > "$BACKUP_DIR/apps/pm2-processes.json" 2>/dev/null || echo "[]" > "$BACKUP_DIR/apps/pm2-processes.json"

    # Backup each PM2 app directory
    for app_path in $(pm2 jlist 2>/dev/null | jq -r '.[].pm2_env.pm_cwd // empty' 2>/dev/null); do
        if [ -d "$app_path" ]; then
            app_name=$(basename "$app_path")
            echo "  - App: $app_name ($app_path)"
            tar czf "$BACKUP_DIR/apps/pm2-$app_name.tar.gz" \
                --exclude='node_modules' \
                --exclude='.git' \
                --exclude='*.log' \
                --exclude='logs' \
                --exclude='.next' \
                --exclude='dist' \
                --exclude='build' \
                -C "$(dirname "$app_path")" "$app_name" 2>/dev/null || true
        fi
    done
else
    echo "  - PM2 not installed"
fi

# ============================================
# 3. NGINX BACKUP
# ============================================
echo ""
echo "[3/10] Nginx..."
if [ -d /etc/nginx ]; then
    echo "  - Backing up nginx configs..."
    sudo tar czf "$BACKUP_DIR/configs/nginx.tar.gz" \
        /etc/nginx/sites-available \
        /etc/nginx/sites-enabled \
        /etc/nginx/nginx.conf \
        /etc/nginx/conf.d 2>/dev/null || true

    # Backup document roots
    for site in /etc/nginx/sites-enabled/*; do
        [ -f "$site" ] || continue
        for root in $(grep -oP 'root\s+\K[^;]+' "$site" 2>/dev/null | sort -u); do
            if [ -d "$root" ] && [[ "$root" != "/var/www/html" ]]; then
                name=$(echo "$root" | tr '/' '_')
                echo "  - Document root: $root"
                sudo tar czf "$BACKUP_DIR/apps/nginx-root$name.tar.gz" "$root" 2>/dev/null || true
            fi
        done
    done
else
    echo "  - Nginx not found"
fi

# ============================================
# 4. APACHE BACKUP
# ============================================
echo ""
echo "[4/10] Apache..."
if [ -d /etc/apache2 ]; then
    echo "  - Backing up apache configs..."
    sudo tar czf "$BACKUP_DIR/configs/apache.tar.gz" \
        /etc/apache2/sites-available \
        /etc/apache2/sites-enabled \
        /etc/apache2/apache2.conf 2>/dev/null || true

    # Backup document roots
    for site in /etc/apache2/sites-enabled/*; do
        [ -f "$site" ] || continue
        for root in $(grep -oP 'DocumentRoot\s+\K[^\s]+' "$site" 2>/dev/null | sort -u); do
            if [ -d "$root" ] && [[ "$root" != "/var/www/html" ]]; then
                name=$(echo "$root" | tr '/' '_')
                echo "  - Document root: $root"
                sudo tar czf "$BACKUP_DIR/apps/apache-root$name.tar.gz" "$root" 2>/dev/null || true
            fi
        done
    done
else
    echo "  - Apache not found"
fi

# ============================================
# 5. SYSTEMD SERVICES BACKUP
# ============================================
echo ""
echo "[5/10] Systemd custom services..."
mkdir -p "$BACKUP_DIR/system/systemd"
for service in /etc/systemd/system/*.service; do
    [ -f "$service" ] || continue
    name=$(basename "$service")

    # Skip system services
    [[ "$name" =~ ^(snap|cloud|ssh|systemd|getty|user@|dbus) ]] && continue

    echo "  - Service: $name"
    sudo cp "$service" "$BACKUP_DIR/system/systemd/" 2>/dev/null || true

    # Try to find and backup the app directory from ExecStart
    exec_path=$(grep -oP 'ExecStart=\K[^\s]+' "$service" 2>/dev/null | head -1)
    if [ -n "$exec_path" ]; then
        # Handle different ExecStart formats
        exec_path=$(echo "$exec_path" | sed 's|^/usr/bin/||' | sed 's|^/bin/||')

        # Get the working directory from service file
        work_dir=$(grep -oP 'WorkingDirectory=\K.*' "$service" 2>/dev/null | head -1)

        if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
            dir_name=$(basename "$work_dir")
            echo "    - Working dir: $work_dir"
            tar czf "$BACKUP_DIR/apps/systemd-$dir_name.tar.gz" \
                --exclude='node_modules' \
                --exclude='.git' \
                --exclude='venv/lib' \
                --exclude='*.log' \
                "$work_dir" 2>/dev/null || true
        fi
    fi
done

# ============================================
# 6. DATABASES BACKUP
# ============================================
echo ""
echo "[6/10] Databases..."

# MySQL/MariaDB
if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
    echo "  - MySQL/MariaDB databases..."
    for db in $(mysql -N -e "SHOW DATABASES" 2>/dev/null | grep -vE '^(information_schema|performance_schema|mysql|sys)$'); do
        echo "    - $db"
        mysqldump --single-transaction --quick --routines --triggers "$db" > "$BACKUP_DIR/databases/mysql-$db.sql" 2>/dev/null || true
    done
fi

# PostgreSQL
if systemctl is-active --quiet postgresql 2>/dev/null; then
    echo "  - PostgreSQL databases..."
    for db in $(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'" 2>/dev/null | xargs); do
        [ -n "$db" ] || continue
        echo "    - $db"
        sudo -u postgres pg_dump --clean --if-exists "$db" > "$BACKUP_DIR/databases/postgres-$db.sql" 2>/dev/null || true
    done
fi

# MongoDB
if systemctl is-active --quiet mongod 2>/dev/null; then
    echo "  - MongoDB databases..."
    mongodump --out "$BACKUP_DIR/databases/mongodb" 2>/dev/null || true
fi

# Redis
if systemctl is-active --quiet redis-server 2>/dev/null || systemctl is-active --quiet redis 2>/dev/null; then
    echo "  - Redis..."
    # Trigger save and copy dump
    redis-cli BGSAVE 2>/dev/null || true
    sleep 2
    sudo cp /var/lib/redis/dump.rdb "$BACKUP_DIR/databases/" 2>/dev/null || true
fi

# ============================================
# 7. HOME DIRECTORIES BACKUP
# ============================================
echo ""
echo "[7/10] Home directories..."
for user_home in /home/*; do
    user=$(basename "$user_home")
    echo "  - User: $user"

    # Calculate size first
    size=$(du -sh "$user_home" 2>/dev/null | cut -f1 || echo "unknown")
    echo "    - Size: $size"

    tar czf "$BACKUP_DIR/apps/home-$user.tar.gz" \
        --exclude='node_modules' \
        --exclude='.cache' \
        --exclude='.npm' \
        --exclude='.local/share/Trash' \
        --exclude='venv/lib' \
        --exclude='.git/objects' \
        --exclude='.nvm' \
        --exclude='.rustup' \
        --exclude='.cargo' \
        --exclude='go/pkg' \
        --exclude='.next' \
        --exclude='dist' \
        --exclude='build' \
        --exclude='*.log' \
        "$user_home" 2>/dev/null || true
done

# ============================================
# 8. CRONTABS BACKUP
# ============================================
echo ""
echo "[8/10] Crontabs..."
for user in $(ls /home 2>/dev/null); do
    if crontab -u "$user" -l > "$BACKUP_DIR/system/crontab-$user" 2>/dev/null; then
        if [ -s "$BACKUP_DIR/system/crontab-$user" ]; then
            echo "  - User: $user (has cron jobs)"
        else
            rm "$BACKUP_DIR/system/crontab-$user"
        fi
    fi
done
sudo cp /etc/crontab "$BACKUP_DIR/system/crontab-system" 2>/dev/null || true

# ============================================
# 9. ENVIRONMENT FILES BACKUP
# ============================================
echo ""
echo "[9/10] Environment files..."
mkdir -p "$BACKUP_DIR/configs/env"
find /home -type f \( -name ".env" -o -name ".env.*" -o -name ".env.local" -o -name ".env.production" \) 2>/dev/null | while read f; do
    if [ -f "$f" ]; then
        # Create unique filename preserving path info
        target="$BACKUP_DIR/configs/env/$(echo "$f" | sed 's|^/||' | tr '/' '_')"
        cp "$f" "$target" 2>/dev/null || true
        echo "  - $f"
    fi
done

# ============================================
# 10. SYSTEM INFO
# ============================================
echo ""
echo "[10/10] System information..."
cat /etc/os-release > "$BACKUP_DIR/system/os-release" 2>/dev/null || true
dpkg --get-selections > "$BACKUP_DIR/system/packages-dpkg.txt" 2>/dev/null || true
pip3 freeze > "$BACKUP_DIR/system/packages-pip.txt" 2>/dev/null || true
npm list -g --depth=0 > "$BACKUP_DIR/system/packages-npm-global.txt" 2>/dev/null || true
cp "$INVENTORY" "$BACKUP_DIR/inventory.json" 2>/dev/null || true

# Save metadata
cat > "$BACKUP_DIR/metadata.json" << EOF
{
  "backup_date": "$(date -Iseconds)",
  "source_hostname": "$(hostname)",
  "source_user": "$BACKUP_USER",
  "os": "$(grep ^NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')",
  "os_version": "$(grep ^VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
}
EOF

# ============================================
# CREATE FINAL ARCHIVE
# ============================================
echo ""
echo "=========================================="
echo "Creating final backup archive..."
tar czf "$FINAL_BACKUP" -C "$BACKUP_DIR" .

# Calculate size
backup_size=$(ls -lh "$FINAL_BACKUP" | awk '{print $5}')

# Cleanup temp directory
rm -rf "$BACKUP_DIR"

echo "=========================================="
echo "Backup Complete!"
echo "=========================================="
echo ""
echo "Backup file: $FINAL_BACKUP"
echo "Size: $backup_size"
echo ""
echo "Contents:"
tar tzf "$FINAL_BACKUP" | head -30
echo "..."
echo ""

# Output the path for the next step
echo "$FINAL_BACKUP"
