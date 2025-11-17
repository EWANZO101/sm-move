#!/bin/bash

# Exit if any command fails
set -e

# === CONFIG ===
DB_NAME="snaily_cadv4"
DB_USER="snailycad"
USER_HOME="/home/snailycad"
BACKUP_DIR="$USER_HOME/backups"
ENV_FILE="$USER_HOME/.env"

# Prompt for remote IP
echo -n "Enter remote server IP: "
read REMOTE_HOST

# Prompt for remote password
echo -n "Enter SSH password for root@$REMOTE_HOST: "
read -s REMOTE_PASS
echo ""

REMOTE_USER="root"
REMOTE_DIR="/home"   # <-- Drop backup in /home on remote VM

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Timestamp
TS=$(date +"%Y-%m-%d_%H-%M-%S")

# Temp backup files
DB_BACKUP="$BACKUP_DIR/db_backup_$TS.sql"
ENV_BACKUP="$BACKUP_DIR/env_backup_$TS"
ARCHIVE="$BACKUP_DIR/snaily_backup_$TS.tar.gz"

echo "=== Backing up PostgreSQL database ($DB_NAME) ==="
pg_dump -U "$DB_USER" "$DB_NAME" > "$DB_BACKUP"

echo "=== Backing up .env ==="
cp "$ENV_FILE" "$ENV_BACKUP"

echo "=== Creating compressed archive ==="
tar -czvf "$ARCHIVE" "$DB_BACKUP" "$ENV_BACKUP"

echo "=== Removing temporary files ==="
rm "$DB_BACKUP" "$ENV_BACKUP"

echo "=== Local backup complete: $ARCHIVE ==="

# === SCP TRANSFER ===
echo "=== Transferring backup to remote server ($REMOTE_HOST) ==="
sshpass -p "$REMOTE_PASS" scp "$ARCHIVE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"

echo "=== Transfer complete! ==="
echo "Backup placed at: root@$REMOTE_HOST:/home"
