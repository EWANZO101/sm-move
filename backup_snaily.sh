#!/bin/bash
set -e

# === CONFIG ===
DB_NAME="snaily-cadv4"
USER_HOME="/home/snailycad"
BACKUP_DIR="$USER_HOME/backups"
ENV_FILE="$USER_HOME/.env"
REMOTE_USER="root"
REMOTE_DIR="/home"
RETENTION_DAYS=7

# === REQUIREMENTS CHECK & AUTO-INSTALL ===
echo "=== Checking requirements ==="

for cmd in pg_dump tar; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is required but not installed."
        exit 1
    fi
done

# Check for sshpass and offer to install it
if ! command -v sshpass >/dev/null 2>&1; then
    echo "WARNING: 'sshpass' is not installed."
    echo -n "Would you like to install it now? (y/n): "
    read -r INSTALL_CHOICE
    
    if [[ "$INSTALL_CHOICE" =~ ^[Yy]$ ]]; then
        echo "Installing sshpass..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install sshpass -y
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install sshpass -y
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install sshpass -y
        else
            echo "ERROR: Could not detect package manager. Please install sshpass manually."
            exit 1
        fi
        
        # Verify installation
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "ERROR: sshpass installation failed."
            exit 1
        fi
        echo "sshpass installed successfully!"
    else
        echo "ERROR: sshpass is required. Please install it manually with:"
        echo "  sudo apt install sshpass"
        exit 1
    fi
fi

echo "All requirements satisfied!"
echo ""

# === DISK SPACE CHECK ===
AVAILABLE=$(df "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -z "$AVAILABLE" ]; then
    # Backup dir doesn't exist yet, check parent directory
    PARENT_DIR=$(dirname "$BACKUP_DIR")
    AVAILABLE=$(df "$PARENT_DIR" | awk 'NR==2 {print $4}')
fi

if [ "$AVAILABLE" -lt 1048576 ]; then
    echo "ERROR: Less than 1GB available. Cannot proceed."
    exit 1
fi

# === DATABASE SIZE ANALYSIS ===
echo "=== Analyzing Database Tables ==="
echo "Database: $DB_NAME"
echo ""

# Get total database size
DB_SIZE=$(sudo -u postgres psql -d "$DB_NAME" -t -c "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));")
echo "Total Database Size: $DB_SIZE"
echo ""

# Get individual table sizes
echo "Table Sizes:"
echo "----------------------------------------"
sudo -u postgres psql -d "$DB_NAME" -c "
SELECT 
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS data_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
" | head -n 50

echo ""
echo "Top 10 Largest Tables:"
echo "----------------------------------------"
sudo -u postgres psql -d "$DB_NAME" -t -c "
SELECT 
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 10;
"

echo ""
echo "Row Counts for Major Tables:"
echo "----------------------------------------"
# Get row counts (this might take a moment for large tables)
sudo -u postgres psql -d "$DB_NAME" -t -c "
SELECT 
    schemaname || '.' || tablename AS table_name,
    n_live_tup AS row_count
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 10;
"

echo ""
read -p "Press Enter to continue with backup..."

# === PROMPTS ===
echo -n "Enter remote server IP: "
read -r REMOTE_HOST

# Validate IP format
if [[ ! $REMOTE_HOST =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid IP address format"
    exit 1
fi

echo -n "Enter SSH password for root@$REMOTE_HOST: "
read -rs REMOTE_PASS
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Timestamp
TS=$(date +"%Y-%m-%d_%H-%M-%S")

# File paths
DB_BACKUP="$BACKUP_DIR/db_backup_$TS.sql"
ENV_BACKUP="$BACKUP_DIR/env_backup_$TS"
ARCHIVE="$BACKUP_DIR/snaily_backup_$TS.tar.gz"
SIZE_REPORT="$BACKUP_DIR/db_size_report_$TS.txt"

# === SAVE SIZE REPORT ===
echo "=== Saving database size report ==="
{
    echo "Database Size Report - $TS"
    echo "========================================"
    echo ""
    echo "Database: $DB_NAME"
    echo "Total Size: $DB_SIZE"
    echo ""
    echo "All Tables (sorted by size):"
    echo "----------------------------------------"
    sudo -u postgres psql -d "$DB_NAME" -c "
    SELECT 
        schemaname || '.' || tablename AS table_name,
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
        pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS data_size,
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) AS index_size
    FROM pg_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
    "
    echo ""
    echo "Row Counts:"
    echo "----------------------------------------"
    sudo -u postgres psql -d "$DB_NAME" -c "
    SELECT 
        schemaname || '.' || tablename AS table_name,
        n_live_tup AS row_count
    FROM pg_stat_user_tables
    ORDER BY n_live_tup DESC;
    "
} > "$SIZE_REPORT"

echo "Size report saved to: $SIZE_REPORT"

echo "=== Backing up PostgreSQL database ($DB_NAME) ==="
if ! sudo -u postgres pg_dump "$DB_NAME" -f "$DB_BACKUP"; then
    echo "ERROR: Database backup failed"
    exit 1
fi

# Get backup file size
BACKUP_SIZE=$(du -h "$DB_BACKUP" | cut -f1)
echo "Backup file size: $BACKUP_SIZE"

echo "=== Backing up .env file ==="
if ! cp "$ENV_FILE" "$ENV_BACKUP"; then
    echo "ERROR: Failed to copy .env file"
    exit 1
fi

echo "=== Creating compressed archive ==="
if ! tar -czf "$ARCHIVE" "$DB_BACKUP" "$ENV_BACKUP" "$SIZE_REPORT"; then
    echo "ERROR: Failed to create archive"
    rm -f "$DB_BACKUP" "$ENV_BACKUP" "$SIZE_REPORT"
    exit 1
fi

# Get archive size
ARCHIVE_SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo "Archive size: $ARCHIVE_SIZE"

echo "=== Verifying archive integrity ==="
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
    echo "ERROR: Archive verification failed"
    exit 1
fi

echo "=== Cleaning up temporary files ==="
rm -f "$DB_BACKUP" "$ENV_BACKUP" "$SIZE_REPORT"

echo "=== LOCAL BACKUP COMPLETE ==="
echo "Archive created at: $ARCHIVE"
echo "Archive size: $ARCHIVE_SIZE"

# === SCP TRANSFER ===
echo "=== Transferring backup to remote server ($REMOTE_HOST) ==="
if ! sshpass -p "$REMOTE_PASS" scp "$ARCHIVE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"; then
    echo "ERROR: Transfer failed"
    exit 1
fi

echo "=== Transfer complete! ==="
echo "Backup successfully placed at: root@$REMOTE_HOST:/home"

# === CLEANUP OLD BACKUPS ===
echo "=== Cleaning up old backups (keeping last $RETENTION_DAYS days) ==="
find "$BACKUP_DIR" -name "snaily_backup_*.tar.gz" -mtime +$RETENTION_DAYS -delete
find "$BACKUP_DIR" -name "db_size_report_*.txt" -mtime +$RETENTION_DAYS -delete

echo ""
echo "=== BACKUP SUMMARY ==="
echo "Database: $DB_NAME ($DB_SIZE)"
echo "Backup File: $BACKUP_SIZE"
echo "Compressed Archive: $ARCHIVE_SIZE"
echo "Remote Location: root@$REMOTE_HOST:/home/$(basename "$ARCHIVE")"
echo ""
echo "=== BACKUP PROCESS COMPLETE ==="
```

## What Changed:

1. **Auto-detects if `sshpass` is missing**
2. **Offers to install it automatically**
3. **Detects your package manager** (apt-get, yum, or dnf)
4. **Installs sshpass** with the appropriate command
5. **Verifies installation** before continuing

Now when you run the script, if `sshpass` is missing, you'll see:
```
WARNING: 'sshpass' is not installed.
Would you like to install it now? (y/n):
