#!/bin/bash
set -e
echo "=== SnailyCAD v4 Simple Backup Script ==="

# Configuration
SNAILYCAD_DIR="/home/snaily-cadv4"
ENV_FILE="$SNAILYCAD_DIR/.env"
BACKUP_DIR="$SNAILYCAD_DIR/backups"
RETENTION_DAYS=7
REMOTE_USER="root"
REMOTE_DIR="/root"  # Changed from /home to /root

echo "SnailyCAD directory: $SNAILYCAD_DIR"
echo "Backup directory: $BACKUP_DIR"
echo ""

### CREATE BACKUP DIRECTORY
echo "=== Ensuring backup directory exists ==="
mkdir -p "$BACKUP_DIR"
chmod 755 "$BACKUP_DIR"
echo "Backup directory ready."
echo ""

### CHECK REQUIRED BINARIES
echo "=== Checking requirements ==="
for cmd in pg_dump tar; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "ERROR: Missing required command: $cmd"
        exit 1
    fi
done

# Auto-install sshpass if missing
if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass is missing. Installing…"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y sshpass
    elif command -v yum >/dev/null 2>&1; then
        yum install -y sshpass
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y sshpass
    else
        echo "ERROR: Could not install sshpass. Install manually."
        exit 1
    fi
fi
echo "All requirements satisfied."
echo ""

### LOAD ENV FILE
echo "=== Loading database credentials from .env ==="
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi

DB_HOST=$(grep "^POSTGRES_HOST=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
DB_PORT=$(grep "^POSTGRES_PORT=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
DB_USER=$(grep "^POSTGRES_USER=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
DB_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
DB_NAME=$(grep "^POSTGRES_DB=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_USER=${DB_USER:-snailycad}
DB_NAME=${DB_NAME:-snailycad}

if [[ -z "$DB_PASSWORD" ]]; then
    echo "ERROR: Could not find POSTGRES_PASSWORD in .env file"
    exit 1
fi

echo "Database: $DB_NAME"
echo "Host: $DB_HOST:$DB_PORT"
echo "User: $DB_USER"
echo ""

### TEST DATABASE CONNECTION
echo "=== Testing database connection ==="
export PGPASSWORD="$DB_PASSWORD"
if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Could not connect to database"
    exit 1
fi
echo "Database connection OK"
echo ""

### GET REMOTE INFO
echo -n "Enter remote server IP: "
read -r REMOTE_HOST
if [[ ! $REMOTE_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid IP address format."
    exit 1
fi

echo -n "Enter SSH password for root@$REMOTE_HOST: "
read -rs REMOTE_PASS
echo ""
echo ""

# Test SSH connection first
echo "=== Testing SSH connection ==="
if ! sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$REMOTE_USER@$REMOTE_HOST" "echo 'SSH OK'" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to remote server via SSH"
    echo "Possible issues:"
    echo "  - Wrong password"
    echo "  - Password authentication disabled on remote server"
    echo "  - Firewall blocking SSH"
    echo ""
    echo "To enable password authentication on remote server, run:"
    echo "  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
    echo "  systemctl restart sshd"
    exit 1
fi
echo "SSH connection OK"
echo ""

### CREATE BACKUP
TS=$(date +"%Y-%m-%d_%H-%M-%S")
DB_BACKUP="$BACKUP_DIR/db_backup_$TS.sql"
ENV_BACKUP="$BACKUP_DIR/env_backup_$TS"
ARCHIVE="$BACKUP_DIR/snaily_backup_$TS.tar.gz"

echo "=== Backing up database ==="
pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" -f "$DB_BACKUP"
DB_SIZE=$(du -h "$DB_BACKUP" | cut -f1)
echo "Database backup created: $DB_BACKUP ($DB_SIZE)"

echo "=== Backing up .env ==="
cp "$ENV_FILE" "$ENV_BACKUP"

echo "=== Creating archive ==="
tar -czf "$ARCHIVE" -C "$BACKUP_DIR" "$(basename "$DB_BACKUP")" "$(basename "$ENV_BACKUP")"
ARCHIVE_SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo "Archive created: $ARCHIVE ($ARCHIVE_SIZE)"

### CLEAN TEMP FILES
rm -f "$DB_BACKUP" "$ENV_BACKUP"
unset PGPASSWORD

### TRANSFER TO REMOTE
echo "=== Transferring to remote server ==="
if sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no "$ARCHIVE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"; then
    echo "Backup transferred successfully to: $REMOTE_HOST:$REMOTE_DIR"
    echo "Transferred file size: $ARCHIVE_SIZE"
else
    echo "ERROR: Failed to transfer backup to remote server"
    echo "The backup is still saved locally at: $ARCHIVE"
    exit 1
fi

### CLEANUP OLD BACKUPS
echo "=== Cleaning backups older than $RETENTION_DAYS days ==="
find "$BACKUP_DIR" -name "snaily_backup_*.tar.gz" -mtime +$RETENTION_DAYS -delete

echo ""
echo "=== BACKUP COMPLETE ==="
echo "Database: $DB_NAME (100% backed up)"
echo "Backup file: $(basename "$ARCHIVE")"
echo "File size: $ARCHIVE_SIZE"
echo "Local: $BACKUP_DIR"
echo "Remote: $REMOTE_HOST:$REMOTE_DIR"
echo "Timestamp: $(date)"
echo "================================"
