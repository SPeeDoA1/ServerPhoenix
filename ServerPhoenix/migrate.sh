#!/bin/bash
# ServerPhoenix Migration Script - Shows real-time progress
# Usage: ./migrate.sh <source_host> <source_user> <source_pass> <dest_host> <dest_user> <dest_pass>

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check arguments
if [ "$#" -lt 6 ]; then
    echo -e "${RED}Usage: $0 <source_host> <source_user> <source_pass> <dest_host> <dest_user> <dest_pass>${NC}"
    echo ""
    echo "Example:"
    echo "  $0 142.93.170.61 root password123 178.128.10.80 root password456"
    exit 1
fi

SOURCE_HOST="$1"
SOURCE_USER="$2"
SOURCE_PASS="$3"
DEST_HOST="$4"
DEST_USER="$5"
DEST_PASS="$6"

BACKUP_FILE="/tmp/migration-backup-$(date +%s).tar.gz"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                    ServerPhoenix Migration                       ║"
echo "║                   Fully Automatic Server Clone                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "Source:      ${YELLOW}${SOURCE_USER}@${SOURCE_HOST}${NC}"
echo -e "Destination: ${YELLOW}${DEST_USER}@${DEST_HOST}${NC}"
echo ""

# Function to run SSH command with progress
ssh_cmd() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local cmd="$4"
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@$host" "$cmd"
}

# Function to run SCP with progress
scp_cmd() {
    local pass="$1"
    local src="$2"
    local dst="$3"
    sshpass -p "$pass" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$src" "$dst"
}

# Step 1: Scan Source
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}[1/7]${NC} ${CYAN}Scanning source server...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
ssh_cmd "$SOURCE_HOST" "$SOURCE_USER" "$SOURCE_PASS" \
    "curl -fsSL https://raw.githubusercontent.com/SPeeDoA1/ServerPhoenix/main/ServerPhoenix/scanner.sh | bash -s /tmp/server-inventory.json"
echo -e "${GREEN}✓ Scan complete${NC}"
echo ""

# Step 2: Backup Source
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}[2/7]${NC} ${CYAN}Creating backup on source server...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
ssh_cmd "$SOURCE_HOST" "$SOURCE_USER" "$SOURCE_PASS" \
    "curl -fsSL https://raw.githubusercontent.com/SPeeDoA1/ServerPhoenix/main/ServerPhoenix/backup.sh | bash -s /tmp/server-inventory.json $SOURCE_USER"
echo -e "${GREEN}✓ Backup complete${NC}"
echo ""

# Step 3: Download Backup
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}[3/7]${NC} ${CYAN}Downloading backup from source...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
scp_cmd "$SOURCE_PASS" "${SOURCE_USER}@${SOURCE_HOST}:/tmp/full-server-backup.tar.gz" "$BACKUP_FILE"
BACKUP_SIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
echo -e "${GREEN}✓ Downloaded: ${BACKUP_FILE} (${BACKUP_SIZE})${NC}"
echo ""

# Step 4: Upload to Destination
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}[4/7]${NC} ${CYAN}Uploading backup to destination...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
scp_cmd "$DEST_PASS" "$BACKUP_FILE" "${DEST_USER}@${DEST_HOST}:/tmp/full-server-backup.tar.gz"
echo -e "${GREEN}✓ Upload complete${NC}"
echo ""

# Step 5: Restore on Destination
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}[5/7]${NC} ${CYAN}Restoring on destination server...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
ssh_cmd "$DEST_HOST" "$DEST_USER" "$DEST_PASS" \
    "curl -fsSL https://raw.githubusercontent.com/SPeeDoA1/ServerPhoenix/main/ServerPhoenix/restore.sh | sudo bash -s /tmp/full-server-backup.tar.gz $DEST_USER"
echo -e "${GREEN}✓ Restore complete${NC}"
echo ""

# Step 6: Verify Services
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}[6/7]${NC} ${CYAN}Verifying services on destination...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
ssh_cmd "$DEST_HOST" "$DEST_USER" "$DEST_PASS" \
    "echo '=== Running Services ===' && systemctl list-units --type=service --state=running --no-pager | head -20 && echo '' && echo '=== Listening Ports ===' && ss -tlnp | head -15"
echo ""

# Step 7: Cleanup
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}[7/7]${NC} ${CYAN}Cleaning up temporary files...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
rm -f "$BACKUP_FILE"
ssh_cmd "$SOURCE_HOST" "$SOURCE_USER" "$SOURCE_PASS" "rm -f /tmp/full-server-backup.tar.gz /tmp/server-inventory.json" 2>/dev/null || true
ssh_cmd "$DEST_HOST" "$DEST_USER" "$DEST_PASS" "rm -f /tmp/full-server-backup.tar.gz" 2>/dev/null || true
echo -e "${GREEN}✓ Cleanup complete${NC}"
echo ""

# Done!
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                    Migration Complete!                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "${GREEN}Next Steps:${NC}"
echo -e "  1. Update DNS records to point to ${YELLOW}${DEST_HOST}${NC}"
echo -e "  2. Get SSL certificates: ${YELLOW}sudo certbot --nginx${NC}"
echo -e "  3. Test your applications"
echo ""
