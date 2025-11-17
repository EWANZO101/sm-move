#!/bin/bash

# Exit on errors
set -e

# === CONFIG ===
DB_NAME="snaily_cadv4"        # Your DB name
DB_USER="snailycad"           # PostgreSQL user
USER_HOME="/home/snailycad"
IMPORT_DIR="/home"

# Find the newest backup archive
ARCHIVE=$(ls -t $IMPORT_DIR/snaily_backup_*.tar.gz | head -1)

if [ -z "$ARCHIVE" ]; then
    echo "ERROR: No snaily_backup_*.tar.gz archive found in $IMPORT_DIR"
    exit 1
fi

echo "Found backup archive:"
echo "$ARCHIVE"
echo ""

# Make temp folder
TEMP_DIR="$IMPORT_DIR/snaily_import_temp"
mkdir -p "$TEMP_DIR"

echo "Extracting archive..."
tar -xzvf "$ARCHIVE" -C "$TEMP_DIR"

# Find extracted files
DB_FILE=$(ls -t $TEMP_DIR/db_backup_*.sql | head -1)
ENV_FILE=$(ls -t $TEMP_DIR/env_backup_* | head -1)

if [ -z "$DB_FILE" ] || [ -z "$ENV_FILE" ]; then
    echo "ERROR: Backup archive does not contain required files."
    exit 1
fi

echo "Database dump found: $DB_FILE"
echo "ENV file found: $ENV_FILE"
echo ""

# === IMPORT DATABASE ===
echo "=== Dropping old DB (optional, comment out if not desired) ==="
# Uncomment if needed:
# dropdb -U "$DB_USER" "$DB_NAME"

echo "=== Restoring database dump into $DB_NAME ==="
psql -U "$DB_USER" -d "$DB_NAME" < "$DB_FILE"

echo "=== Database import complete ==="

# === RESTORE .env ===
echo "Restoring .env file to $USER_HOME/.env"
cp "$ENV_FILE" "$USER_HOME/.env"
chown "$DB_USER":"$DB_USER" "$USER_HOME/.env"

echo "=== .env restored ==="

# Cleanup
echo "Cleaning up temp files..."
rm -rf "$TEMP_DIR"

echo ""
echo "=== Import Process Complete! ==="
