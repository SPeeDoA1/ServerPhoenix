# ServerPhoenix

**Automated Server Migration System** - Clone any Linux server to another with a single webhook call.

Like a phoenix rising from the ashes, ServerPhoenix brings your entire server back to life on a new machine!

## Features

- **100% Automated** - Just provide server credentials, everything else is automatic
- **Universal** - Works with any Linux server, not just specific apps
- **Auto-Detection** - Automatically finds and backs up all running services
- **Zero Pre-Installation** - Scripts download and run on-the-fly from GitHub

## What Gets Migrated

| Category | Detection Method | What's Backed Up |
|----------|-----------------|------------------|
| Docker | `docker ps`, compose files | Containers, volumes, compose files |
| PM2 Apps | `pm2 jlist` | Process list + app directories |
| Systemd Services | `/etc/systemd/system/*.service` | Service files + working directories |
| Nginx | `/etc/nginx/sites-enabled/*` | Configs + document roots |
| Apache | `/etc/apache2/sites-enabled/*` | Configs + document roots |
| MySQL/MariaDB | Running service | Full database dumps |
| PostgreSQL | Running service | Full database dumps |
| MongoDB | Running service | Full database dumps |
| Redis | Running service | RDB dump |
| Crontabs | `crontab -l` | User cron jobs |
| Environment | `.env*` files | All env files |
| Home Directories | `/home/*` | User data (excluding cache/node_modules) |

## Quick Start

### Option 1: Manual Usage

```bash
# On source server - scan and backup
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ServerPhoenix/main/scanner.sh | bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ServerPhoenix/main/backup.sh | bash

# Transfer backup to new server
scp /tmp/full-server-backup.tar.gz user@new-server:/tmp/

# On destination server - restore
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ServerPhoenix/main/restore.sh | sudo bash -s /tmp/full-server-backup.tar.gz username
```

### Option 2: n8n Automation (Recommended)

1. Import the workflow JSON into n8n
2. Configure SSH credentials for your servers
3. Call the webhook:

```bash
curl -X POST https://your-n8n.com/webhook/migrate-server \
  -H "Content-Type: application/json" \
  -d '{
    "source": {
      "host": "OLD_SERVER_IP",
      "user": "speedo",
      "credential": "old-server-ssh"
    },
    "destination": {
      "host": "NEW_SERVER_IP",
      "user": "speedo",
      "credential": "new-server-ssh"
    }
  }'
```

## Scripts

### scanner.sh
Scans the server and creates a JSON inventory of all detected services.

```bash
./scanner.sh [output_file]
# Default: /tmp/server-inventory.json
```

### backup.sh
Creates a comprehensive backup based on the scanner output.

```bash
./backup.sh [inventory_file] [username]
# Default: Uses /tmp/server-inventory.json and current user
# Output: /tmp/full-server-backup.tar.gz
```

### restore.sh
Restores everything to a new server from the backup file.

```bash
./restore.sh <backup-file.tar.gz> [username]
# Example: ./restore.sh /tmp/full-server-backup.tar.gz speedo
```

## n8n Workflow

The workflow automates the entire process:

1. **Webhook Trigger** - Receives source/destination server info
2. **SSH to Source** - Download & run scanner.sh
3. **SSH to Source** - Download & run backup.sh
4. **SCP Transfer** - Copy backup to destination
5. **SSH to Destination** - Download & run restore.sh
6. **Verify** - Check all services are running

See `workflow.json` for the importable n8n workflow.

## Requirements

### Source Server (Old)
- SSH access
- sudo privileges

### Destination Server (New)
- SSH access
- sudo privileges
- Internet access (to download packages)

### n8n Instance
- SSH credentials stored for both servers
- Webhook endpoint accessible

## Post-Migration Steps

After the automation completes:

1. **Update DNS** - Point your domains to the new server IP
2. **Get SSL Certificates:**
   ```bash
   sudo apt install certbot python3-certbot-nginx
   sudo certbot --nginx
   ```
3. **Verify Services:**
   ```bash
   systemctl list-units --type=service --state=running
   pm2 status
   ```

## Exclusions

The backup excludes large/regeneratable directories:
- `node_modules/` (reinstalled via npm install)
- `.cache/`
- `.npm/`
- `.git/objects/`
- `venv/lib/` (dependencies reinstalled)
- `.next/`, `dist/`, `build/` (build artifacts)
- `*.log` files

## Security Notes

- Backups contain sensitive data (.env files, database dumps)
- Transfer backups over secure connections (SCP uses SSH)
- Delete backup files after migration
- Consider encrypting backups for long-term storage

## Troubleshooting

### Nginx config test fails
Usually means SSL certificates are missing. Run certbot after DNS is updated.

### PM2 apps not starting
Check if dependencies installed correctly:
```bash
cd /path/to/app
npm install
pm2 start ecosystem.config.js
```

### Database connection errors
Verify database service is running:
```bash
sudo systemctl status mysql
sudo systemctl status postgresql
```

## License

MIT License - Use freely for personal and commercial projects.

## Author

Created by ServerPhoenix Automation System
