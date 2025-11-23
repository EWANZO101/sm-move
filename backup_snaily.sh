#!/bin/bash
set -e

### ============================================
###  SNAILYCAD V4 COMPLETE BACKUP SCRIPT
### ============================================
echo "=== SnailyCAD v4 Complete Backup Script ==="

# Configuration
SNAILYCAD_DIR="/home/snaily-cadv4"
ENV_FILE="$SNAILYCAD_DIR/.env"
BACKUP_DIR="$SNAILYCAD_DIR/backups"
RETENTION_DAYS=7
REMOTE_USER="root"
REMOTE_DIR="/home"

echo "SnailyCAD directory: $SNAILYCAD_DIR"
echo "Backup directory: $BACKUP_DIR"
echo ""

### ============================================
### CREATE BACKUP DIRECTORY
### ============================================
echo "=== Ensuring backup directory exists ==="
mkdir -p "$BACKUP_DIR"
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
### CHECK & LOAD ENV FILE
### ============================================
echo "=== Loading database credentials from .env ==="

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi

# Extract database credentials from .env
DB_HOST=$(grep "^POSTGRES_HOST=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
DB_PORT=$(grep "^POSTGRES_PORT=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
DB_USER=$(grep "^POSTGRES_USER=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
DB_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
DB_NAME=$(grep "^POSTGRES_DB=" "$ENV_FILE" | cut -d '=' -f2 | tr -d '"' | tr -d "'")

# Set defaults if not found
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

### ============================================
### TEST DATABASE CONNECTION
### ============================================
echo "=== Testing database connection ==="

export PGPASSWORD="$DB_PASSWORD"

if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Could not connect to database"
    echo "Please verify your database credentials in $ENV_FILE"
    exit 1
fi

echo "Database connection OK"
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
### DATABASE SIZE REPORT (ROBUST VERSION)
### ============================================
echo "=== Generating size report ==="
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
SELECT 
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
    pg_size_pretty(pg_indexes_size(schemaname || '.' || tablename)) AS index_size
FROM pg_tables 
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND pg_total_relation_size(schemaname || '.' || tablename) IS NOT NULL
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC;
" > "$SIZE_REPORT" 2>&1 || {
    echo "Warning: Size report generation had issues, but continuing with backup..."
    echo "Database size report generation completed with warnings" > "$SIZE_REPORT"
}

echo "Size report generated: $SIZE_REPORT"

### ============================================
### DATABASE BACKUP
### ============================================
echo "=== Backing up database ==="
if pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" -f "$DB_BACKUP"; then
    echo "Database backup created: $DB_BACKUP"
else
    echo "ERROR: Failed to create database backup"
    exit 1
fi

### ============================================
### ENV BACKUP
### ============================================
echo "=== Backing up .env ==="
cp "$ENV_FILE" "$ENV_BACKUP"
echo "Env backup created: $ENV_BACKUP"

### ============================================
### CREATE ARCHIVE
### ============================================
echo "=== Creating archive ==="
tar -czf "$ARCHIVE" -C "$BACKUP_DIR" \
    "$(basename "$DB_BACKUP")" \
    "$(basename "$ENV_BACKUP")" \
    "$(basename "$SIZE_REPORT")"

echo "Archive created: $ARCHIVE"

### ============================================
### CLEAN TEMP FILES
### ============================================
rm -f "$DB_BACKUP" "$ENV_BACKUP" "$SIZE_REPORT"
echo "Temporary files cleaned"

# Unset password from environment
unset PGPASSWORD

### ============================================
### SCP TRANSFER
### ============================================
echo "=== Transferring to remote server ==="
if sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no "$ARCHIVE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"; then
    echo "Backup transferred successfully to: $REMOTE_HOST:$REMOTE_DIR"
else
    echo "ERROR: Failed to transfer backup to remote server"
    exit 1
fi

### ============================================
### CLEAN OLD BACKUPS
### ============================================
echo "=== Cleaning backups older than $RETENTION_DAYS days ==="
find "$BACKUP_DIR" -name "snaily_backup_*.tar.gz" -mtime +$RETENTION_DAYS -delete
echo "Old backups cleaned"

### ============================================
### BACKUP COMPLETE
### ============================================
echo ""
echo "=== BACKUP COMPLETE ==="
echo "Backup archive: $(basename "$ARCHIVE")"
echo "Local location: $BACKUP_DIR"
echo "Remote location: $REMOTE_HOST:$REMOTE_DIR"
echo "File size: $(du -h "$ARCHIVE" | cut -f1)"
echo "Timestamp: $(date)"
echo "================================"
