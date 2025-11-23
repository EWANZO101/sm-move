#!/bin/bash

# =============================================
# SnailyCAD Self-Healing Database Import Script
# =============================================

set -euo pipefail

# Script configuration
LOG_FILE="/tmp/snaily_import_$(date +%Y%m%d_%H%M%S).log"
BACKUP_SEARCH_DIR="/home"
TEMP_DIR="/home/snaily_import_temp_$$"  # $$ adds process ID for uniqueness

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Database configuration
DB_NAME="snaily_cadv4"
DB_USER="snailycad"
DB_PASSWORD="snailycad_pass"

# Logging functions
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

# Error handling and cleanup
cleanup() {
    log "Cleaning up temporary files..."
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_success "Cleaned up temporary directory"
    fi
}

trap cleanup EXIT

# Self-healing functions
setup_postgresql_auth() {
    log "Setting up PostgreSQL authentication..."
    
    # Check if pg_hba.conf exists
    if ! sudo ls /etc/postgresql/*/main/pg_hba.conf >/dev/null 2>&1; then
        log_error "PostgreSQL configuration not found. Is PostgreSQL installed?"
        return 1
    fi
    
    # Backup current config
    sudo cp /etc/postgresql/*/main/pg_hba.conf /etc/postgresql/*/main/pg_hba.conf.backup 2>/dev/null || true
    
    # Update authentication method from peer to md5
    if sudo grep -q "peer" /etc/postgresql/*/main/pg_hba.conf; then
        sudo sed -i 's/local   all             all                                     peer/local   all             all                                     md5/g' /etc/postgresql/*/main/pg_hba.conf
        log_success "Updated PostgreSQL authentication to use md5"
    else
        log_info "PostgreSQL authentication already uses md5 or other method"
    fi
    
    # Restart PostgreSQL
    if sudo systemctl restart postgresql; then
        log_success "PostgreSQL restarted successfully"
    else
        log_error "Failed to restart PostgreSQL"
        return 1
    fi
}

create_snailycad_user() {
    log "Creating snailycad system user..."
    
    # Check if user exists
    if id "$DB_USER" &>/dev/null; then
        log_info "User $DB_USER already exists"
    else
        if sudo useradd -m -s /bin/bash "$DB_USER"; then
            log_success "Created system user: $DB_USER"
        else
            log_error "Failed to create system user: $DB_USER"
            return 1
        fi
    fi
    
    # Ensure home directory exists and has correct permissions
    sudo mkdir -p "/home/$DB_USER"
    sudo chown "$DB_USER:$DB_USER" "/home/$DB_USER"
    sudo chmod 755 "/home/$DB_USER"
}

setup_database_user() {
    log "Setting up database user..."
    
    # Check if PostgreSQL user exists and create if not
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
        log_info "Database user $DB_USER already exists"
        
        # Update password
        if sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"; then
            log_success "Updated password for database user: $DB_USER"
        fi
    else
        # Create new user
        if sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD' CREATEDB;"; then
            log_success "Created database user: $DB_USER"
        else
            log_error "Failed to create database user: $DB_USER"
            return 1
        fi
    fi
}

check_dependencies() {
    log "Checking dependencies..."
    
    local missing_deps=()
    
    # Check required commands
    for cmd in psql createdb dropdb pg_restore tar gunzip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Installing PostgreSQL and required tools..."
        
        if command -v apt-get &>/dev/null; then
            sudo apt-get update
            sudo apt-get install -y postgresql postgresql-contrib tar gzip
        elif command -v yum &>/dev/null; then
            sudo yum install -y postgresql postgresql-server tar gzip
        else
            log_error "Cannot install dependencies - unknown package manager"
            return 1
        fi
    else
        log_success "All dependencies available"
    fi
}

# Main import functions
find_backup_archive() {
    log "Searching for backup archive in $BACKUP_SEARCH_DIR..."
    
    local backup_files=()
    
    # Find all .tar.gz files in backup directory
    while IFS= read -r -d $'\0' file; do
        backup_files+=("$file")
    done < <(find "$BACKUP_SEARCH_DIR" -maxdepth 1 -name "*.tar.gz" -print0 2>/dev/null)
    
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        log_error "No backup archives found in $BACKUP_SEARCH_DIR"
        return 1
    fi
    
    # Sort by modification time (newest first) and pick the most recent
    local latest_backup
    latest_backup=$(ls -t "${backup_files[@]}" | head -n1)
    
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        log_success "Found backup archive: $latest_backup"
        echo "$latest_backup"
    else
        log_error "Could not determine latest backup file"
        return 1
    fi
}

extract_backup_archive() {
    local archive_path="$1"
    
    log "Creating temporary directory: $TEMP_DIR"
    if ! mkdir -p "$TEMP_DIR"; then
        log_error "Failed to create temporary directory"
        return 1
    fi
    
    log "Extracting archive..."
    if tar -xzf "$archive_path" -C "$TEMP_DIR"; then
        log_success "Archive extracted successfully"
    else
        log_error "Failed to extract archive"
        return 1
    fi
}

locate_backup_files() {
    log "Locating backup files..."
    
    local env_file db_dump
    
    # Find environment file
    env_file=$(find "$TEMP_DIR" -name "env_backup_*" -type f | head -n1)
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        log_success "ENV file found: $(basename "$env_file")"
    else
        log_error "No ENV backup file found"
        return 1
    fi
    
    # Find database dump
    db_dump=$(find "$TEMP_DIR" -name "db_backup_*" -type f \( -name "*.sql" -o -name "*.dump" \) | head -n1)
    if [[ -n "$db_dump" && -f "$db_dump" ]]; then
        local dump_size
        dump_size=$(du -h "$db_dump" | cut -f1)
        log_success "Database dump found: $(basename "$db_dump")"
        log_info "Database dump size: $dump_size"
    else
        log_error "No database dump file found"
        return 1
    fi
    
    echo "$env_file" "$db_dump"
}

setup_database() {
    log "=== CONFLICT RESOLUTION: Dropping existing database ==="
    log_warning "This will DELETE the existing '$DB_NAME' database and all its data!"
    
    # Check if database exists
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        log_warning "Database '$DB_NAME' exists - dropping..."
        if dropdb -U postgres "$DB_NAME"; then
            log_success "Dropped existing database: $DB_NAME"
        else
            log_error "Failed to drop database: $DB_NAME"
            return 1
        fi
    else
        log_info "Database '$DB_NAME' does not exist - will create new"
    fi
    
    log "Creating fresh database '$DB_NAME'..."
    if createdb -U "$DB_USER" "$DB_NAME"; then
        log_success "Database created successfully"
    else
        log_error "Failed to create database"
        return 1
    fi
}

import_database() {
    local db_dump="$1"
    
    log "=== Importing database dump into $DB_NAME ==="
    log_info "This may take a few minutes..."
    
    # Set password for psql commands
    export PGPASSWORD="$DB_PASSWORD"
    
    # Check file type and import accordingly
    if [[ "$db_dump" == *.sql ]]; then
        # SQL dump
        if psql -h localhost -U "$DB_USER" -d "$DB_NAME" -f "$db_dump" >> "$LOG_FILE" 2>&1; then
            log_success "Database import completed successfully"
        else
            log_error "Failed to import SQL dump"
            return 1
        fi
    elif [[ "$db_dump" == *.dump ]]; then
        # PostgreSQL custom format dump
        if pg_restore -h localhost -U "$DB_USER" -d "$DB_NAME" "$db_dump" >> "$LOG_FILE" 2>&1; then
            log_success "Database import completed successfully"
        else
            log_error "Failed to restore database dump"
            return 1
        fi
    else
        log_error "Unsupported database dump format: $db_dump"
        return 1
    fi
    
    # Verify import
    local db_size
    db_size=$(psql -h localhost -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" 2>/dev/null || echo "unknown")
    log_info "Imported database size: $db_size"
}

restore_env_file() {
    local env_file="$1"
    
    log "=== Restoring .env file ==="
    
    local target_env="/home/$DB_USER/.env"
    
    # Ensure target directory exists
    sudo mkdir -p "/home/$DB_USER"
    
    log "Copying .env file to $target_env"
    if sudo cp "$env_file" "$target_env"; then
        sudo chown "$DB_USER:$DB_USER" "$target_env"
        sudo chmod 600 "$target_env"
        log_success "Environment file restored successfully"
        
        # Display first few lines for verification
        log_info "Environment file preview:"
        head -n 10 "$target_env" | while IFS= read -r line; do
            log_info "  $line"
        done
    else
        log_error "Failed to copy .env file"
        return 1
    fi
}

verify_import() {
    log "=== Verifying import ==="
    
    # Check if database is accessible and has tables
    local table_count
    table_count=$(psql -h localhost -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
    
    if [[ "$table_count" -gt 0 ]]; then
        log_success "Import verification successful: Found $table_count tables in database"
    else
        log_warning "No tables found in database - import may have issues"
    fi
    
    # Check if .env file exists and has content
    if sudo test -f "/home/$DB_USER/.env" && sudo test -s "/home/$DB_USER/.env"; then
        log_success "Environment file verified"
    else
        log_warning "Environment file missing or empty"
    fi
}

main() {
    log "=== SnailyCAD Self-Healing Database Import Script ==="
    log "Log file: $LOG_FILE"
    
    # Initial setup
    if ! check_dependencies; then
        log_error "Dependency check failed"
        exit 1
    fi
    
    if ! setup_postgresql_auth; then
        log_error "PostgreSQL setup failed"
        exit 1
    fi
    
    if ! create_snailycad_user; then
        log_error "User creation failed"
        exit 1
    fi
    
    if ! setup_database_user; then
        log_error "Database user setup failed"
        exit 1
    fi
    
    # Find and extract backup
    local backup_archive
    backup_archive=$(find_backup_archive) || exit 1
    
    local archive_size
    archive_size=$(du -h "$backup_archive" | cut -f1)
    log_info "Archive size: $archive_size"
    
    if ! extract_backup_archive "$backup_archive"; then
        log_error "Archive extraction failed"
        exit 1
    fi
    
    # Locate backup files
    local backup_files
    backup_files=$(locate_backup_files) || exit 1
    
    read -r env_file db_dump <<< "$backup_files"
    
    # Database operations
    if ! setup_database; then
        log_error "Database setup failed"
        exit 1
    fi
    
    if ! import_database "$db_dump"; then
        log_error "Database import failed"
        exit 1
    fi
    
    # Restore environment file
    if ! restore_env_file "$env_file"; then
        log_error "Environment file restoration failed"
        exit 1
    fi
    
    # Final verification
    verify_import
    
    log_success "=== SnailyCAD import completed successfully ==="
    log "Database: $DB_NAME"
    log "User: $DB_USER"
    log "Environment file: /home/$DB_USER/.env"
    log "Check log file for details: $LOG_FILE"
}

# Run main function
main "$@"
