#!/bin/bash
# ServerPhoenix - Enhanced Restore Script v2.0
# Restores full backup to a new server with proper dependency installation
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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_step() {
    echo -e "${GREEN}$1${NC}"
}

log_info() {
    echo -e "${CYAN}  $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}  [WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}  [ERROR] $1${NC}"
}

echo ""
echo "=========================================="
echo "ServerPhoenix - Enhanced Server Restore"
echo "=========================================="
echo "Backup: $BACKUP_FILE"
echo "User: $DEST_USER"
echo "=========================================="

# ============================================
# STEP 1: EXTRACT BACKUP
# ============================================
echo ""
log_step "[1/14] Extracting backup..."
tar xzf "$BACKUP_FILE" -C "$RESTORE_DIR"

if [ -f "$RESTORE_DIR/metadata.json" ]; then
    log_info "Source: $(jq -r '.source_hostname // "unknown"' "$RESTORE_DIR/metadata.json")"
    log_info "Date: $(jq -r '.backup_date // "unknown"' "$RESTORE_DIR/metadata.json")"
fi

# ============================================
# STEP 2: INSTALL BASE PACKAGES
# ============================================
echo ""
log_step "[2/14] Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq curl wget git jq software-properties-common apt-transport-https ca-certificates gnupg lsb-release

# ============================================
# STEP 3: RESTORE HOME DIRECTORIES FIRST
# ============================================
echo ""
log_step "[3/14] Restoring user home directories..."
for home_backup in "$RESTORE_DIR"/apps/home-*.tar.gz; do
    [ -f "$home_backup" ] || continue
    backup_user=$(basename "$home_backup" .tar.gz | sed 's/home-//')
    log_info "User: $backup_user"

    # Create user if doesn't exist
    if ! id "$backup_user" &>/dev/null; then
        log_info "Creating user $backup_user..."
        sudo useradd -m -s /bin/bash "$backup_user" 2>/dev/null || true
    fi

    sudo tar xzf "$home_backup" -C / 2>/dev/null || true
    sudo chown -R "$backup_user:$backup_user" "/home/$backup_user" 2>/dev/null || true
done

# ============================================
# STEP 4: DETECT AND INSTALL NODE.JS
# ============================================
echo ""
log_step "[4/14] Checking for Node.js applications..."

node_needed=false

# Check for package.json in any restored home directory
for user_home in /home/*/; do
    if find "$user_home" -name "package.json" -type f 2>/dev/null | head -1 | grep -q .; then
        node_needed=true
        break
    fi
done

# Check systemd services for Node apps
if [ -d "$RESTORE_DIR/system/systemd" ]; then
    for service_file in "$RESTORE_DIR"/system/systemd/*.service; do
        [ -f "$service_file" ] || continue
        if grep -qE "node|npm|pm2" "$service_file" 2>/dev/null; then
            node_needed=true
            break
        fi
    done
fi

if [ "$node_needed" = true ]; then
    log_info "Node.js applications detected, installing Node.js 20.x..."
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1
        sudo apt-get install -y -qq nodejs
    fi
    log_info "Node.js $(node --version)"

    # Install PM2 globally
    log_info "Installing PM2..."
    sudo npm install -g pm2 >/dev/null 2>&1
    log_info "PM2 $(pm2 --version)"
fi

# ============================================
# STEP 5: DETECT AND INSTALL PYTHON
# ============================================
echo ""
log_step "[5/14] Checking for Python applications..."

python_needed=false

# Check for requirements.txt or venv in any restored home directory
for user_home in /home/*/; do
    if find "$user_home" -name "requirements.txt" -type f 2>/dev/null | head -1 | grep -q .; then
        python_needed=true
        break
    fi
    if find "$user_home" -type d -name "venv" 2>/dev/null | head -1 | grep -q .; then
        python_needed=true
        break
    fi
done

if [ "$python_needed" = true ]; then
    log_info "Python applications detected, installing Python..."
    sudo apt-get install -y -qq python3 python3-pip python3-venv python3-dev build-essential
    log_info "Python $(python3 --version)"
fi

# ============================================
# STEP 6: INSTALL NPM DEPENDENCIES
# ============================================
echo ""
log_step "[6/14] Installing NPM dependencies..."

if command -v npm &>/dev/null; then
    for user_home in /home/*/; do
        user=$(basename "$user_home")

        # Find all package.json files
        while IFS= read -r package_json; do
            [ -f "$package_json" ] || continue
            app_dir=$(dirname "$package_json")
            app_name=$(basename "$app_dir")

            # Skip node_modules
            [[ "$app_dir" == *"node_modules"* ]] && continue

            log_info "Installing: $app_name ($app_dir)"

            # Fix ownership first
            sudo chown -R "$user:$user" "$app_dir" 2>/dev/null || true

            # Install dependencies as the user
            (
                cd "$app_dir"
                sudo -u "$user" npm install --production 2>&1 | tail -3
            ) || log_warn "npm install failed for $app_name"

        done < <(find "$user_home" -name "package.json" -type f ! -path "*/node_modules/*" 2>/dev/null)
    done
else
    log_info "No Node.js installed, skipping npm dependencies"
fi

# ============================================
# STEP 7: SETUP PYTHON VIRTUALENVS
# ============================================
echo ""
log_step "[7/14] Setting up Python virtual environments..."

if command -v python3 &>/dev/null; then
    for user_home in /home/*/; do
        user=$(basename "$user_home")

        # Find all requirements.txt files
        while IFS= read -r req_file; do
            [ -f "$req_file" ] || continue
            app_dir=$(dirname "$req_file")
            app_name=$(basename "$app_dir")

            # Skip venv directories
            [[ "$app_dir" == *"venv"* ]] && continue
            [[ "$app_dir" == *".venv"* ]] && continue

            log_info "Setting up Python env: $app_name ($app_dir)"

            # Fix ownership
            sudo chown -R "$user:$user" "$app_dir" 2>/dev/null || true

            # Create venv if it doesn't exist
            if [ ! -d "$app_dir/venv" ]; then
                log_info "  Creating virtualenv..."
                sudo -u "$user" python3 -m venv "$app_dir/venv" 2>/dev/null || true
            fi

            # Install requirements
            if [ -d "$app_dir/venv" ]; then
                log_info "  Installing requirements..."
                (
                    cd "$app_dir"
                    sudo -u "$user" bash -c "source venv/bin/activate && pip install --upgrade pip >/dev/null 2>&1 && pip install -r requirements.txt 2>&1 | tail -5"
                ) || log_warn "pip install failed for $app_name"
            fi

        done < <(find "$user_home" -name "requirements.txt" -type f ! -path "*/venv/*" ! -path "*/.venv/*" 2>/dev/null)
    done
else
    log_info "No Python installed, skipping virtualenvs"
fi

# ============================================
# STEP 8: RESTORE NGINX
# ============================================
echo ""
log_step "[8/14] Restoring Nginx..."
if [ -f "$RESTORE_DIR/configs/nginx.tar.gz" ]; then
    log_info "Installing Nginx..."
    sudo apt-get install -y -qq nginx

    log_info "Restoring nginx configs..."
    sudo tar xzf "$RESTORE_DIR/configs/nginx.tar.gz" -C / 2>/dev/null || true

    # Restore document roots
    for root_backup in "$RESTORE_DIR"/apps/nginx-root*.tar.gz; do
        [ -f "$root_backup" ] || continue
        log_info "Document root: $(basename "$root_backup")"
        sudo tar xzf "$root_backup" -C / 2>/dev/null || true
    done

    # Remove SSL configs temporarily (will get new certs)
    sudo rm -f /etc/nginx/sites-enabled/*-ssl* 2>/dev/null || true

    # Comment out SSL lines in configs
    sudo find /etc/nginx -name "*.conf" -exec sed -i 's/ssl_certificate/#ssl_certificate/g' {} \; 2>/dev/null || true
    sudo find /etc/nginx -name "*.conf" -exec sed -i 's/listen 443/#listen 443/g' {} \; 2>/dev/null || true

    if sudo nginx -t 2>/dev/null; then
        sudo systemctl enable nginx 2>/dev/null || true
        sudo systemctl restart nginx 2>/dev/null || true
        log_info "Nginx configured and running"
    else
        log_warn "Nginx config test failed - checking..."
        sudo nginx -t 2>&1 | head -5
    fi
else
    log_info "No Nginx config to restore"
fi

# ============================================
# STEP 9: RESTORE APACHE (disabled if nginx running)
# ============================================
echo ""
log_step "[9/14] Restoring Apache..."
if [ -f "$RESTORE_DIR/configs/apache.tar.gz" ]; then
    # Check if nginx is using port 80
    if ss -tlnp | grep -q ":80.*nginx"; then
        log_warn "Nginx already on port 80, skipping Apache"
    else
        log_info "Installing Apache..."
        sudo apt-get install -y -qq apache2
        sudo tar xzf "$RESTORE_DIR/configs/apache.tar.gz" -C / 2>/dev/null || true

        if sudo apache2ctl configtest 2>/dev/null; then
            sudo systemctl enable apache2 2>/dev/null || true
            sudo systemctl restart apache2 2>/dev/null || true
            log_info "Apache configured and running"
        else
            log_warn "Apache config test failed"
        fi
    fi
else
    log_info "No Apache config to restore"
fi

# ============================================
# STEP 10: RESTORE DATABASES
# ============================================
echo ""
log_step "[10/14] Restoring databases..."

# MySQL
for sql in "$RESTORE_DIR"/databases/mysql-*.sql; do
    [ -f "$sql" ] || continue
    log_info "Installing MySQL..."
    sudo apt-get install -y -qq mysql-server
    sudo systemctl start mysql 2>/dev/null || true

    db=$(basename "$sql" .sql | sed 's/mysql-//')
    log_info "Restoring MySQL database: $db"
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\`" 2>/dev/null || true
    mysql "$db" < "$sql" 2>/dev/null || true
    break  # Only install once
done

# PostgreSQL
for sql in "$RESTORE_DIR"/databases/postgres-*.sql; do
    [ -f "$sql" ] || continue
    log_info "Installing PostgreSQL..."
    sudo apt-get install -y -qq postgresql
    sudo systemctl start postgresql 2>/dev/null || true

    db=$(basename "$sql" .sql | sed 's/postgres-//')
    log_info "Restoring PostgreSQL database: $db"
    sudo -u postgres createdb "$db" 2>/dev/null || true
    sudo -u postgres psql "$db" < "$sql" 2>/dev/null || true
done

# MongoDB
if [ -d "$RESTORE_DIR/databases/mongodb" ]; then
    log_info "Installing MongoDB..."
    curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor 2>/dev/null || true
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list >/dev/null 2>&1 || true
    sudo apt-get update -qq 2>/dev/null || true
    sudo apt-get install -y -qq mongodb-org 2>/dev/null || sudo apt-get install -y -qq mongodb 2>/dev/null || true
    sudo systemctl start mongod 2>/dev/null || true
    mongorestore "$RESTORE_DIR/databases/mongodb" 2>/dev/null || true
fi

# Redis
if [ -f "$RESTORE_DIR/databases/dump.rdb" ]; then
    log_info "Installing Redis..."
    sudo apt-get install -y -qq redis-server
    sudo systemctl stop redis-server 2>/dev/null || true
    sudo cp "$RESTORE_DIR/databases/dump.rdb" /var/lib/redis/
    sudo chown redis:redis /var/lib/redis/dump.rdb
    sudo systemctl start redis-server 2>/dev/null || true
    log_info "Redis restored"
fi

# ============================================
# STEP 11: RESTORE AND START SYSTEMD SERVICES
# ============================================
echo ""
log_step "[11/14] Restoring systemd services..."

if [ -d "$RESTORE_DIR/system/systemd" ] && [ "$(ls -A "$RESTORE_DIR/system/systemd" 2>/dev/null)" ]; then
    # First restore the app directories that services depend on
    for app_backup in "$RESTORE_DIR"/apps/systemd-*.tar.gz; do
        [ -f "$app_backup" ] || continue
        log_info "Restoring app: $(basename "$app_backup")"
        sudo tar xzf "$app_backup" -C / 2>/dev/null || true
    done

    # Process each service
    for service_file in "$RESTORE_DIR"/system/systemd/*.service; do
        [ -f "$service_file" ] || continue
        service_name=$(basename "$service_file" .service)

        # Skip DigitalOcean/system services
        [[ "$service_name" =~ ^(do-agent|droplet-agent|vpc-peering|iscsi|syslog|vmtoolsd)$ ]] && continue

        log_info "Service: $service_name"

        # Get working directory from service file
        work_dir=$(grep "WorkingDirectory=" "$service_file" | cut -d= -f2 | head -1)

        if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
            log_info "  WorkingDirectory: $work_dir"

            # Determine the user who owns this directory
            dir_user=$(stat -c '%U' "$work_dir" 2>/dev/null || echo "$DEST_USER")

            # Install dependencies if needed
            if [ -f "$work_dir/package.json" ]; then
                log_info "  Running npm install..."
                (cd "$work_dir" && sudo -u "$dir_user" npm install --production 2>&1 | tail -2) || true
            fi

            if [ -f "$work_dir/requirements.txt" ]; then
                log_info "  Setting up Python venv..."
                if [ ! -d "$work_dir/venv" ]; then
                    sudo -u "$dir_user" python3 -m venv "$work_dir/venv" 2>/dev/null || true
                fi
                if [ -d "$work_dir/venv" ]; then
                    (cd "$work_dir" && sudo -u "$dir_user" bash -c "source venv/bin/activate && pip install -r requirements.txt" 2>&1 | tail -2) || true
                fi
            fi
        fi

        # Copy service file
        sudo cp "$service_file" /etc/systemd/system/ 2>/dev/null || true
    done

    sudo systemctl daemon-reload
else
    log_info "No custom services to restore"
fi

# ============================================
# STEP 12: START PYTHON APPS (GUNICORN/DJANGO)
# ============================================
echo ""
log_step "[12/16] Starting Python applications..."

# Install gunicorn globally if Python exists
if command -v python3 &>/dev/null; then
    sudo pip3 install gunicorn 2>/dev/null || true
fi

# Find and start Django apps
for user_home in /home/*/; do
    user=$(basename "$user_home")

    # Find Django apps (have manage.py)
    while IFS= read -r manage_py; do
        [ -f "$manage_py" ] || continue
        app_dir=$(dirname "$manage_py")
        app_name=$(basename "$app_dir")

        # Skip if in venv
        [[ "$app_dir" == *"venv"* ]] && continue
        [[ "$app_dir" == *".venv"* ]] && continue

        # Look for wsgi.py
        wsgi_file=$(find "$app_dir" -name "wsgi.py" -type f ! -path "*/venv/*" 2>/dev/null | head -1)
        if [ -n "$wsgi_file" ]; then
            wsgi_module=$(dirname "$wsgi_file" | xargs basename)
            log_info "Django app: $app_name (wsgi: $wsgi_module)"

            # Setup virtualenv if not exists
            if [ ! -d "$app_dir/venv" ]; then
                log_info "  Creating virtualenv..."
                sudo -u "$user" python3 -m venv "$app_dir/venv" 2>/dev/null || true
            fi

            # Install requirements
            if [ -f "$app_dir/requirements.txt" ] && [ -d "$app_dir/venv" ]; then
                log_info "  Installing requirements..."
                sudo -u "$user" bash -c "cd $app_dir && source venv/bin/activate && pip install --upgrade pip wheel setuptools >/dev/null 2>&1 && pip install gunicorn && pip install -r requirements.txt" 2>&1 | tail -3
            fi

            # Create logs directory
            sudo -u "$user" mkdir -p "$app_dir/logs" 2>/dev/null || true

            # Default port (check processes backup for original port)
            port=8000
            if [ -f "$RESTORE_DIR/processes/python-servers.txt" ]; then
                orig_port=$(grep -E "gunicorn|uvicorn" "$RESTORE_DIR/processes/python-servers.txt" 2>/dev/null | grep -oP '0\.0\.0\.0:\K\d+' | head -1)
                [ -n "$orig_port" ] && port=$orig_port
            fi
            # Also check .env
            if [ -f "$app_dir/.env" ]; then
                env_port=$(grep -oP '^PORT=\K\d+' "$app_dir/.env" 2>/dev/null | head -1)
                [ -n "$env_port" ] && port=$env_port
            fi

            log_info "  Starting on port $port..."

            # Check if start.sh exists and use it
            if [ -f "$app_dir/start.sh" ]; then
                log_info "  Found start.sh, using it..."
                chmod +x "$app_dir/start.sh"

                cat > "/tmp/gunicorn-$app_name.service" << SERVICEEOF
[Unit]
Description=Gunicorn for $app_name
After=network.target

[Service]
User=$user
Group=$user
WorkingDirectory=$app_dir
ExecStart=/bin/bash $app_dir/start.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICEEOF
            else
                # Create systemd service for gunicorn directly
                cat > "/tmp/gunicorn-$app_name.service" << SERVICEEOF
[Unit]
Description=Gunicorn for $app_name
After=network.target

[Service]
User=$user
Group=$user
WorkingDirectory=$app_dir
ExecStart=$app_dir/venv/bin/gunicorn --workers 3 --bind 0.0.0.0:$port $wsgi_module.wsgi:application
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICEEOF
            fi

            sudo mv "/tmp/gunicorn-$app_name.service" "/etc/systemd/system/gunicorn-$app_name.service"
            sudo systemctl daemon-reload
            sudo systemctl enable "gunicorn-$app_name" 2>/dev/null || true

            if sudo systemctl start "gunicorn-$app_name" 2>/dev/null; then
                log_info "  ✓ Started gunicorn-$app_name on port $port"
            else
                log_warn "  Systemd failed, trying direct start..."
                sudo -u "$user" bash -c "cd $app_dir && source venv/bin/activate && nohup gunicorn --workers 3 --bind 0.0.0.0:$port $wsgi_module.wsgi:application > logs/gunicorn.log 2>&1 &" || true
            fi
        fi
    done < <(find "$user_home" -name "manage.py" -type f ! -path "*/venv/*" 2>/dev/null)
done

# ============================================
# STEP 13: START NODE.JS APPS WITH PM2
# ============================================
echo ""
log_step "[13/16] Starting Node.js applications..."

if command -v pm2 &>/dev/null; then
    for user_home in /home/*/; do
        user=$(basename "$user_home")

        # Look for package.json with start scripts
        while IFS= read -r package_json; do
            [ -f "$package_json" ] || continue
            app_dir=$(dirname "$package_json")
            app_name=$(basename "$app_dir")

            # Skip node_modules and frontend
            [[ "$app_dir" == *"node_modules"* ]] && continue
            [[ "$app_dir" == *"Frontend"* ]] && continue

            # Check if it has a start script
            if jq -e '.scripts.start' "$package_json" >/dev/null 2>&1; then
                log_info "Node app: $app_name"

                # Fix ownership
                sudo chown -R "$user:$user" "$app_dir" 2>/dev/null || true

                # Install dependencies if needed
                if [ ! -d "$app_dir/node_modules" ]; then
                    log_info "  Installing npm dependencies..."
                    (cd "$app_dir" && sudo -u "$user" npm install 2>&1 | tail -2) || true
                fi

                # Start with PM2
                (
                    cd "$app_dir"
                    sudo -u "$user" pm2 delete "$app_name" 2>/dev/null || true
                    sudo -u "$user" pm2 start npm --name "$app_name" -- start 2>&1 | tail -2
                ) || log_warn "Failed to start $app_name"
            fi

        done < <(find "$user_home" -name "package.json" -type f ! -path "*/node_modules/*" -maxdepth 4 2>/dev/null)
    done

    # Save PM2 config and setup startup
    pm2 save 2>/dev/null || true
    startup_cmd=$(pm2 startup systemd -u "$DEST_USER" --hp "/home/$DEST_USER" 2>/dev/null | grep "sudo" | head -1)
    [ -n "$startup_cmd" ] && eval "$startup_cmd" 2>/dev/null || true
else
    log_info "PM2 not installed, skipping"
fi

# ============================================
# STEP 14: START ALL SYSTEMD SERVICES
# ============================================
echo ""
log_step "[14/16] Starting systemd services..."

# Start custom systemd services
for service in /etc/systemd/system/*.service; do
    [ -f "$service" ] || continue
    name=$(basename "$service" .service)

    # Skip system services
    [[ "$name" =~ ^(snap|cloud|ssh|systemd|getty|user@|dbus|do-agent|droplet-agent|vpc-peering|iscsi|syslog|vmtoolsd|apache-htcacheclean)$ ]] && continue

    log_info "Starting: $name"
    sudo systemctl enable "$name" 2>/dev/null || true
    if ! sudo systemctl start "$name" 2>/dev/null; then
        log_warn "Failed to start $name"
        sudo systemctl status "$name" --no-pager 2>&1 | tail -5
    fi
done

# ============================================
# STEP 15: RESTORE ENVIRONMENT FILES
# ============================================
echo ""
log_step "[15/16] Restoring environment files..."

if [ -d "$RESTORE_DIR/configs/env" ]; then
    for env_file in "$RESTORE_DIR"/configs/env/*; do
        [ -f "$env_file" ] || continue

        # Convert filename back to path (underscores to slashes)
        original_name=$(basename "$env_file")
        original_path=$(echo "$original_name" | sed 's|_|/|g')

        if [ -d "$(dirname "/$original_path")" ]; then
            log_info "Restoring: /$original_path"
            sudo cp "$env_file" "/$original_path" 2>/dev/null || true
        fi
    done
fi

# ============================================
# STEP 16: FINAL VERIFICATION
# ============================================
echo ""
log_step "[16/16] Final verification..."

# Wait a moment for services to start
sleep 3

# Check all listening ports
log_info "Checking listening ports..."
ss -tlnp 2>/dev/null | grep LISTEN | while read line; do
    port=$(echo "$line" | awk '{print $4}' | grep -oP ':\K\d+$')
    proc=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+')
    [ -n "$port" ] && log_info "  Port $port: $proc"
done

# ============================================
# CLEANUP
# ============================================
rm -rf "$RESTORE_DIR"

# ============================================
# FINAL STATUS
# ============================================
echo ""
echo "=========================================="
echo "ServerPhoenix - Restore Complete!"
echo "=========================================="
echo ""
echo -e "${GREEN}Services Status:${NC}"
echo "----------------"
systemctl list-units --type=service --state=running --no-pager 2>/dev/null | grep -vE "^(UNIT|LOAD|●)" | head -20 || true
echo ""
echo -e "${GREEN}Listening Ports:${NC}"
echo "----------------"
ss -tlnp 2>/dev/null | head -15 || true
echo ""
echo -e "${GREEN}PM2 Processes:${NC}"
echo "--------------"
pm2 list 2>/dev/null || echo "PM2 not running"
echo ""
echo "=========================================="
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "=========================================="
echo ""
echo "1. Update DNS records to point to:"
echo "   $(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""
echo "2. Install SSL certificates:"
echo "   sudo apt install certbot python3-certbot-nginx -y"
echo "   sudo certbot --nginx"
echo ""
echo "3. Check service status:"
echo "   systemctl status <service-name>"
echo "   pm2 logs"
echo ""
echo "4. Test your applications!"
echo ""
echo "=========================================="
