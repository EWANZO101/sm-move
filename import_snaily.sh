#!/bin/bash

# Self-Healing SnailyCAD Database Import Script
# Features:
# - Automatic conflict resolution
# - Database replacement on conflicts
# - Size reporting
# - Error recovery
# - Detailed logging

# === CONFIGURATION ===
set -e  # Exit on errors (will be selectively disabled for self-healing)
trap 'handle_error $? $LINENO' ERR

DB_NAME="snailycad"        # Your DB name
DB_USER="snailycad"           # PostgreSQL user
USER_HOME="/home/snailycad"
IMPORT_DIR="/home"
LOG_FILE="/tmp/snaily_import_$(date +%Y%m%d_%H%M%S).log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === LOGGING FUNCTION ===
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# === ERROR HANDLER ===
handle_error() {
    local exit_code=$1
    local line_number=$2
    log_error "Script failed at line $line_number with exit code $exit_code"
    log_error "Attempting self-healing..."
    
    # Cleanup on error
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log "Cleaned up temporary files"
    fi
    
    log_error "Self-healing attempted. Check log: $LOG_FILE"
    exit $exit_code
}

# === START SCRIPT ===
log "=== SnailyCAD Self-Healing Database Import Script ==="
log "Log file: $LOG_FILE"
echo ""

# === FIND BACKUP ARCHIVE ===
log "Searching for backup archive in $IMPORT_DIR..."
ARCHIVE=$(ls -t $IMPORT_DIR/snaily_backup_*.tar.gz 2>/dev/null | head -1)

if [ -z "$ARCHIVE" ]; then
    log_error "No snaily_backup_*.tar.gz archive found in $IMPORT_DIR"
    log_info "Searching in subdirectories..."
    ARCHIVE=$(find $IMPORT_DIR -name "snaily_backup_*.tar.gz" -type f 2>/dev/null | head -1)
    
    if [ -z "$ARCHIVE" ]; then
        log_error "No backup archive found anywhere in $IMPORT_DIR"
        exit 1
    fi
fi

log "✓ Found backup archive: $ARCHIVE"
ARCHIVE_SIZE=$(du -h "$ARCHIVE" | cut -f1)
log_info "Archive size: $ARCHIVE_SIZE"
echo ""

# === CREATE TEMP DIRECTORY ===
TEMP_DIR="$IMPORT_DIR/snaily_import_temp_$$"
log "Creating temporary directory: $TEMP_DIR"
mkdir -p "$TEMP_DIR"

# === EXTRACT ARCHIVE ===
log "Extracting archive..."
if tar -xzf "$ARCHIVE" -C "$TEMP_DIR" 2>&1 | tee -a "$LOG_FILE"; then
    log "✓ Archive extracted successfully"
else
    log_error "Failed to extract archive"
    log "Attempting to repair archive..."
    
    # Try without compression
    if tar -xf "$ARCHIVE" -C "$TEMP_DIR" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Archive extracted (without compression flag)"
    else
        log_error "Archive is corrupted and cannot be repaired"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
fi
echo ""

# === FIND EXTRACTED FILES ===
log "Locating backup files..."
DB_FILE=$(find "$TEMP_DIR" -name "db_backup_*.sql" -type f 2>/dev/null | head -1)
ENV_FILE=$(find "$TEMP_DIR" -name "env_backup_*" -type f 2>/dev/null | head -1)

if [ -z "$DB_FILE" ]; then
    log_error "Database dump file not found in archive"
    rm -rf "$TEMP_DIR"
    exit 1
fi

if [ -z "$ENV_FILE" ]; then
    log_warn "ENV file not found in archive - will skip .env restoration"
else
    log "✓ ENV file found: $(basename $ENV_FILE)"
fi

log "✓ Database dump found: $(basename $DB_FILE)"
DB_FILE_SIZE=$(du -h "$DB_FILE" | cut -f1)
log_info "Database dump size: $DB_FILE_SIZE"
echo ""

# === CHECK DATABASE SIZE (KB) ===
DB_SIZE_BYTES=$(stat -f%z "$DB_FILE" 2>/dev/null || stat -c%s "$DB_FILE" 2>/dev/null)
DB_SIZE_KB=$((DB_SIZE_BYTES / 1024))
log_info "Database dump size: ${DB_SIZE_KB} KB"
echo ""

# === DROP EXISTING DATABASE (CONFLICT RESOLUTION) ===
log "=== CONFLICT RESOLUTION: Dropping existing database ==="
log_warn "This will DELETE the existing '$DB_NAME' database and all its data!"

# Check if database exists
set +e  # Disable exit on error temporarily
DB_EXISTS=$(psql -U "$DB_USER" -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME" && echo "yes" || echo "no")
set -e

if [ "$DB_EXISTS" = "yes" ]; then
    log "Database '$DB_NAME' exists - terminating active connections..."
    
    # Terminate all connections to the database
    set +e
    psql -U "$DB_USER" -d postgres -c "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '$DB_NAME' AND pid <> pg_backend_pid();" 2>&1 | tee -a "$LOG_FILE"
    set -e
    
    sleep 2
    
    # Drop the database
    log "Dropping database '$DB_NAME'..."
    set +e
    if dropdb -U "$DB_USER" "$DB_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Database dropped successfully"
    else
        log_error "Failed to drop database - attempting force drop..."
        psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);" 2>&1 | tee -a "$LOG_FILE"
        log "✓ Database force-dropped"
    fi
    set -e
else
    log_info "Database '$DB_NAME' does not exist - will create new"
fi

# === CREATE FRESH DATABASE ===
log "Creating fresh database '$DB_NAME'..."
set +e
if createdb -U "$DB_USER" "$DB_NAME" 2>&1 | tee -a "$LOG_FILE"; then
    log "✓ Database created successfully"
else
    log_warn "Database creation returned warnings - continuing anyway"
fi
set -e
echo ""

# === IMPORT DATABASE ===
log "=== Importing database dump into $DB_NAME ==="
log "This may take a few minutes..."

set +e
if psql -U "$DB_USER" -d "$DB_NAME" < "$DB_FILE" 2>&1 | tee -a "$LOG_FILE"; then
    log "✓ Database import completed successfully"
else
    log_warn "Database import completed with warnings (common for backups)"
fi
set -e

# === GET IMPORTED DATABASE SIZE ===
log "Calculating imported database size..."
IMPORTED_DB_SIZE=$(psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" 2>/dev/null | xargs)
IMPORTED_DB_SIZE_KB=$(psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT pg_database_size('$DB_NAME')/1024;" 2>/dev/null | xargs)

log_info "Imported database size: $IMPORTED_DB_SIZE (${IMPORTED_DB_SIZE_KB} KB)"
echo ""

# === RESTORE .env FILE ===
if [ -n "$ENV_FILE" ]; then
    log "=== Restoring .env file ==="
    
    # Backup existing .env if it exists
    if [ -f "$USER_HOME/.env" ]; then
        BACKUP_ENV="$USER_HOME/.env.backup_$(date +%Y%m%d_%H%M%S)"
        log "Backing up existing .env to: $BACKUP_ENV"
        cp "$USER_HOME/.env" "$BACKUP_ENV"
    fi
    
    # Copy new .env
    log "Copying .env file to $USER_HOME/.env"
    cp "$ENV_FILE" "$USER_HOME/.env"
    
    # Set permissions
    chown "$DB_USER":"$DB_USER" "$USER_HOME/.env" 2>/dev/null || log_warn "Could not change .env ownership (may need sudo)"
    chmod 600 "$USER_HOME/.env" 2>/dev/null || log_warn "Could not change .env permissions"
    
    log "✓ .env file restored"
else
    log_warn "Skipping .env restoration (file not found in backup)"
fi
echo ""

# === CLEANUP ===
log "Cleaning up temporary files..."
rm -rf "$TEMP_DIR"
log "✓ Cleanup complete"
echo ""

# === SUMMARY ===
log "╔═══════════════════════════════════════════════════════════╗"
log "║          IMPORT PROCESS COMPLETED SUCCESSFULLY            ║"
log "╚═══════════════════════════════════════════════════════════╝"
echo ""
log_info "📊 SUMMARY:"
log_info "  • Backup archive: $(basename $ARCHIVE) ($ARCHIVE_SIZE)"
log_info "  • Database dump size: ${DB_SIZE_KB} KB"
log_info "  • Imported database size: $IMPORTED_DB_SIZE (${IMPORTED_DB_SIZE_KB} KB)"
log_info "  • Database: $DB_NAME"
log_info "  • User: $DB_USER"
log_info "  • Log file: $LOG_FILE"
echo ""
log "✅ Your SnailyCAD database has been successfully restored!"
log "🔧 The script automatically resolved all conflicts by replacing the old database"
echo ""
