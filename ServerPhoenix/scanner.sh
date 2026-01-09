#!/bin/bash
# ServerPhoenix - Scanner Script
# Auto-detects all services, apps, databases on the server
# Outputs JSON inventory for backup process
#
# Usage: scanner.sh [output_file]
# Default output: /tmp/server-inventory.json

set -e
OUTPUT_FILE="${1:-/tmp/server-inventory.json}"

echo "=========================================="
echo "ServerPhoenix - Server Scanner"
echo "=========================================="

# Install jq if not present
if ! command -v jq &>/dev/null; then
    echo "[Setup] Installing jq..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq jq
fi

echo "[Scanning] Detecting services and applications..."

# Start JSON
cat > "$OUTPUT_FILE" << 'INVENTORY_START'
{
INVENTORY_START

# ============================================
# Docker Detection
# ============================================
echo '  "docker": {' >> "$OUTPUT_FILE"
if command -v docker &>/dev/null; then
    echo "[Found] Docker installed"
    echo '    "installed": true,' >> "$OUTPUT_FILE"

    # Containers
    containers=$(docker ps -a --format '{{json .}}' 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]')
    echo '    "containers": '"$containers"',' >> "$OUTPUT_FILE"

    # Volumes
    volumes=$(docker volume ls --format '{{json .}}' 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]')
    echo '    "volumes": '"$volumes"',' >> "$OUTPUT_FILE"

    # Compose files
    compose_files=$(find /home /opt /srv -name "docker-compose*.yml" -o -name "compose.yml" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
    echo '    "compose_files": '"$compose_files" >> "$OUTPUT_FILE"
else
    echo "[Skip] Docker not installed"
    echo '    "installed": false' >> "$OUTPUT_FILE"
fi
echo '  },' >> "$OUTPUT_FILE"

# ============================================
# PM2 Detection
# ============================================
echo '  "pm2": {' >> "$OUTPUT_FILE"
if command -v pm2 &>/dev/null; then
    echo "[Found] PM2 installed"
    echo '    "installed": true,' >> "$OUTPUT_FILE"
    processes=$(pm2 jlist 2>/dev/null || echo '[]')
    echo '    "processes": '"$processes" >> "$OUTPUT_FILE"
else
    echo "[Skip] PM2 not installed"
    echo '    "installed": false' >> "$OUTPUT_FILE"
fi
echo '  },' >> "$OUTPUT_FILE"

# ============================================
# Nginx Detection
# ============================================
echo '  "nginx": {' >> "$OUTPUT_FILE"
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "[Found] Nginx running"
    echo '    "running": true,' >> "$OUTPUT_FILE"
    sites=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
    echo '    "sites": '"$sites" >> "$OUTPUT_FILE"
else
    echo "[Skip] Nginx not running"
    echo '    "running": false' >> "$OUTPUT_FILE"
fi
echo '  },' >> "$OUTPUT_FILE"

# ============================================
# Apache Detection
# ============================================
echo '  "apache": {' >> "$OUTPUT_FILE"
if systemctl is-active --quiet apache2 2>/dev/null; then
    echo "[Found] Apache running"
    echo '    "running": true,' >> "$OUTPUT_FILE"
    sites=$(ls /etc/apache2/sites-enabled/ 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
    echo '    "sites": '"$sites" >> "$OUTPUT_FILE"
else
    echo "[Skip] Apache not running"
    echo '    "running": false' >> "$OUTPUT_FILE"
fi
echo '  },' >> "$OUTPUT_FILE"

# ============================================
# Databases Detection
# ============================================
echo '  "databases": {' >> "$OUTPUT_FILE"

# MySQL/MariaDB
echo '    "mysql": {' >> "$OUTPUT_FILE"
if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
    echo "[Found] MySQL/MariaDB running"
    echo '      "running": true,' >> "$OUTPUT_FILE"
    databases=$(mysql -N -e "SHOW DATABASES" 2>/dev/null | grep -vE '^(information_schema|performance_schema|mysql|sys)$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
    echo '      "databases": '"$databases" >> "$OUTPUT_FILE"
else
    echo "[Skip] MySQL not running"
    echo '      "running": false' >> "$OUTPUT_FILE"
fi
echo '    },' >> "$OUTPUT_FILE"

# PostgreSQL
echo '    "postgresql": {' >> "$OUTPUT_FILE"
if systemctl is-active --quiet postgresql 2>/dev/null; then
    echo "[Found] PostgreSQL running"
    echo '      "running": true,' >> "$OUTPUT_FILE"
    databases=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'" 2>/dev/null | xargs | tr ' ' '\n' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
    echo '      "databases": '"$databases" >> "$OUTPUT_FILE"
else
    echo "[Skip] PostgreSQL not running"
    echo '      "running": false' >> "$OUTPUT_FILE"
fi
echo '    },' >> "$OUTPUT_FILE"

# MongoDB
echo '    "mongodb": {' >> "$OUTPUT_FILE"
if systemctl is-active --quiet mongod 2>/dev/null; then
    echo "[Found] MongoDB running"
    echo '      "running": true,' >> "$OUTPUT_FILE"
    databases=$(mongosh --quiet --eval "db.adminCommand('listDatabases').databases.map(d=>d.name)" 2>/dev/null | jq -c '.' 2>/dev/null || echo '[]')
    echo '      "databases": '"$databases" >> "$OUTPUT_FILE"
else
    echo "[Skip] MongoDB not running"
    echo '      "running": false' >> "$OUTPUT_FILE"
fi
echo '    },' >> "$OUTPUT_FILE"

# Redis
echo '    "redis": {' >> "$OUTPUT_FILE"
if systemctl is-active --quiet redis-server 2>/dev/null || systemctl is-active --quiet redis 2>/dev/null; then
    echo "[Found] Redis running"
    echo '      "running": true' >> "$OUTPUT_FILE"
else
    echo "[Skip] Redis not running"
    echo '      "running": false' >> "$OUTPUT_FILE"
fi
echo '    }' >> "$OUTPUT_FILE"
echo '  },' >> "$OUTPUT_FILE"

# ============================================
# Systemd Custom Services
# ============================================
echo "[Scanning] Custom systemd services..."
systemd_services=$(find /etc/systemd/system -maxdepth 1 -name "*.service" -type f 2>/dev/null | xargs -I {} basename {} 2>/dev/null | grep -v -E '^(snap|cloud|ssh|systemd|getty|user@)' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
echo '  "systemd_services": '"$systemd_services"',' >> "$OUTPUT_FILE"

# ============================================
# Listening Ports
# ============================================
echo "[Scanning] Network ports..."
ports=$(ss -tlnp 2>/dev/null | tail -n +2 | awk '{print $4}' | sed 's/.*://' | sort -nu | jq -R -s 'split("\n") | map(select(length > 0) | tonumber)' 2>/dev/null || echo '[]')
echo '  "ports": '"$ports"',' >> "$OUTPUT_FILE"

# ============================================
# User Home Directories
# ============================================
echo "[Scanning] User directories..."
users=$(ls /home 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
echo '  "users": '"$users"',' >> "$OUTPUT_FILE"

# ============================================
# Environment Files
# ============================================
echo "[Scanning] Environment files..."
env_files=$(find /home -name ".env" -o -name ".env.*" -o -name ".env.local" -o -name ".env.production" 2>/dev/null | head -100 | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
echo '  "env_files": '"$env_files"',' >> "$OUTPUT_FILE"

# ============================================
# Crontabs
# ============================================
echo "[Scanning] Cron jobs..."
echo '  "crontabs": {' >> "$OUTPUT_FILE"
first=true
for user in $(ls /home 2>/dev/null); do
    cron=$(crontab -u "$user" -l 2>/dev/null | grep -v "^#" | grep -v "^$" || true)
    if [ -n "$cron" ]; then
        if [ "$first" = false ]; then
            echo ',' >> "$OUTPUT_FILE"
        fi
        first=false
        cron_json=$(echo "$cron" | jq -R -s 'split("\n") | map(select(length > 0))')
        echo -n '    "'"$user"'": '"$cron_json" >> "$OUTPUT_FILE"
    fi
done
echo '' >> "$OUTPUT_FILE"
echo '  },' >> "$OUTPUT_FILE"

# ============================================
# System Info
# ============================================
echo "[Scanning] System information..."
os_name=$(grep ^NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Unknown")
os_version=$(grep ^VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Unknown")
echo '  "system": {' >> "$OUTPUT_FILE"
echo '    "os": "'"$os_name"'",' >> "$OUTPUT_FILE"
echo '    "version": "'"$os_version"'",' >> "$OUTPUT_FILE"
echo '    "hostname": "'"$(hostname)"'",' >> "$OUTPUT_FILE"
echo '    "scan_date": "'"$(date -Iseconds)"'"' >> "$OUTPUT_FILE"
echo '  }' >> "$OUTPUT_FILE"

# Close JSON
echo '}' >> "$OUTPUT_FILE"

echo ""
echo "=========================================="
echo "Scan Complete!"
echo "Inventory saved to: $OUTPUT_FILE"
echo "=========================================="

# Validate JSON
if jq empty "$OUTPUT_FILE" 2>/dev/null; then
    echo "[OK] Valid JSON output"
else
    echo "[WARN] JSON validation failed, but file was created"
fi

# Show summary
echo ""
echo "Summary:"
jq -r '
  "  Docker containers: \(.docker.containers // [] | length)",
  "  Docker volumes: \(.docker.volumes // [] | length)",
  "  PM2 processes: \(.pm2.processes // [] | length)",
  "  Nginx sites: \(.nginx.sites // [] | length)",
  "  Custom services: \(.systemd_services // [] | length)",
  "  Users: \(.users // [] | length)",
  "  Env files: \(.env_files // [] | length)",
  "  Listening ports: \(.ports // [] | length)"
' "$OUTPUT_FILE" 2>/dev/null || true
