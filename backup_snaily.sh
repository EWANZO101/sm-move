#!/bin/bash
set -e

### ============================================
###  AUTO-DETECT CORRECT USER & PATHS
### ============================================
echo "=== Auto-detecting SnailyCAD user ==="

# Priority order: snailycad, cad, ubuntu, current user, first non-root home user
CANDIDATES=("snailycad" "cad" "ubuntu" "$SUDO_USER" "$USER")

DETECTED_USER=""
for usr in "${CANDIDATES[@]}"; do
    if id "$usr" >/dev/null 2>&1; then
        DETECTED_USER="$usr"
        break
    fi
done

# If no match found, detect first non-root folder in /home
if [[ -z "$DETECTED_USER" ]]; then
    DETECTED_USER=$(ls /home | grep -v "root" | head -n1)
fi

if [[ -z "$DETECTED_USER" ]]; then
    echo "ERROR: Could not detect SnailyCAD user."
    exit 1
fi

echo "Detected user: $DETECTED_USER"

USER_HOME="/home/$DETECTED_USER"
BACKUP_DIR="$USER_HOME/backups"
ENV_FILE="$USER_HOME/.env"

DB_NAME="snaily-cadv4"
REMOTE_USER="root"
REMOTE_DIR="/home"
RETENTION_DAYS=7

echo "SnailyCAD user home: $USER_HOME"
echo "Backup directory: $BACKUP_DIR"
echo ""

### ============================================
### CREATE BACKUP DIRECTORY AND FIX PERMISSIONS
### ============================================
echo "=== Ensuring backup directory exists ==="
mkdir -p "$BACKUP_DIR"

# Ensure directory belongs to the detected user
chown -R "$DETECTED_USER":"$DETECTED_USER" "$BACKUP_DIR"
chmod 755 "$BACKUP_DIR"

echo "Backup directory ready."
echo ""

### ============================================
### CHECK REQUIRED BINARIES
### ============================================
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

### ============================================
### CHECK DATABASE & ENV FILE
### ============================================
echo "=== Validating database & .env file ==="

if ! sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1; then
    echo "ERROR: PostgreSQL not accessible."
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi

echo "Database OK"
echo ".env file found"
echo ""

### ============================================
### PROMPT FOR REMOTE BACKUP TARGET
### ============================================
echo -n "Enter remote server IP: "
read -r REMOTE_HOST

if [[ ! $REMOTE_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid IP address format."
    exit 1
fi

echo -n "Enter SSH password for root@$REMOTE_HOST: "
read -rs REMOTE_PASS
echo ""

### ============================================
### TIMESTAMP & FILENAMES
### ============================================
TS=$(date +"%Y-%m-%d_%H-%M-%S")
DB_BACKUP="$BACKUP_DIR/db_backup_$TS.sql"
ENV_BACKUP="$BACKUP_DIR/env_backup_$TS"
SIZE_REPORT="$BACKUP_DIR/db_size_report_$TS.txt"
ARCHIVE="$BACKUP_DIR/snaily_backup_$TS.tar.gz"

### ============================================
### DATABASE SIZE REPORT
### ============================================
echo "=== Generating size report ==="
sudo -u postgres psql -d "$DB_NAME" -c "
SELECT table_name,
       pg_size_pretty(total_bytes) AS total_size,
       pg_size_pretty(index_bytes) AS index_size,
       pg_size_pretty(toast_bytes) AS toast_size,
       pg_size_pretty(table_bytes) AS table_size
FROM (
    SELECT *, total_bytes-index_bytes-COALESCE(toast_bytes,0) AS table_bytes
    FROM (
        SELECT relname AS table_name,
               pg_total_relation_size(relid) AS total_bytes,
               pg_indexes_size(relid) AS index_bytes,
               pg_total_relation_size(reltoastrelid) AS toast_bytes
        FROM pg_catalog.pg_statio_user_tables
    ) AS x
) AS y
ORDER BY total_bytes DESC;
" > "$SIZE_REPORT"

### ============================================
### DATABASE BACKUP
### ============================================
echo "=== Backing up database ==="
sudo -u postgres pg_dump "$DB_NAME" -f "$DB_BACKUP"

### ============================================
### ENV BACKUP
### ============================================
echo "=== Backing up .env ==="
cp "$ENV_FILE" "$ENV_BACKUP"

### ============================================
### CREATE ARCHIVE
### ============================================
echo "=== Creating archive ==="
tar -czf "$ARCHIVE" "$DB_BACKUP" "$ENV_BACKUP" "$SIZE_REPORT"

### ============================================
### CLEAN TEMP FILES
### ============================================
rm -f "$DB_BACKUP" "$ENV_BACKUP" "$SIZE_REPORT"

echo "Local backup created: $ARCHIVE"

### ============================================
### SCP TRANSFER
### ============================================
echo "=== Transferring to remote server ==="
sshpass -p "$REMOTE_PASS" scp "$ARCHIVE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"

echo "Backup transferred to: $REMOTE_HOST"

### ============================================
### CLEAN OLD BACKUPS
### ============================================
echo "=== Cleaning backups older than $RETENTION_DAYS days ==="
find "$BACKUP_DIR" -name "snaily_backup_*.tar.gz" -mtime +$RETENTION_DAYS -delete

echo "=== BACKUP COMPLETE ==="
