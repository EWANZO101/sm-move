#!/bin/bash

# SnailyCAD Database Import Script - Fully Functional Version
set -euo pipefail

# Configuration
LOG_FILE="/tmp/snaily_import_$(date +%Y%m%d_%H%M%S).log"
BACKUP_SEARCH_DIR="/home"
TEMP_DIR="/tmp/snaily_import_temp_$$"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Database config
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_HOST=""
DB_PORT=""

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

# Cleanup function
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        log "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
        log_success "Cleaned up temporary directory"
    fi
}

trap cleanup EXIT

# Check if running with appropriate privileges
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root user"
    else
        if ! sudo -n true 2>/dev/null; then
            log_info "This script requires sudo access. You may be prompted for your password."
            if ! sudo true; then
                log_error "Failed to obtain sudo access"
                exit 1
            fi
        fi
        log_info "Running with sudo privileges"
    fi
    
    log_success "Privilege check passed"
}

# Extract database credentials from .env file
extract_db_credentials() {
    local env_file="$1"
    
    log "Extracting database credentials from .env file..."
    
    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi
    
    # Extract credentials with improved parsing
    DB_HOST=$(grep -E '^DATABASE_HOST=' "$env_file" | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' | tr -d '[:space:]' || echo "")
    DB_PORT=$(grep -E '^DATABASE_PORT=' "$env_file" | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' | tr -d '[:space:]' || echo "")
    DB_NAME=$(grep -E '^DATABASE_NAME=' "$env_file" | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' | tr -d '[:space:]' || echo "")
    DB_USER=$(grep -E '^DATABASE_USER=' "$env_file" | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' | tr -d '[:space:]' || echo "")
    DB_PASSWORD=$(grep -E '^DATABASE_PASSWORD=' "$env_file" | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' || echo "")
    
    # Set defaults if empty
    DB_HOST=${DB_HOST:-"localhost"}
    DB_PORT=${DB_PORT:-"5432"}
    DB_NAME=${DB_NAME:-"snaily_cadv4"}
    DB_USER=${DB_USER:-"snailycad"}
    DB_PASSWORD=${DB_PASSWORD:-"snailycad_pass"}
    
    log_success "Database credentials extracted:"
    log_info "  Host: $DB_HOST"
    log_info "  Port: $DB_PORT"
    log_info "  Database: $DB_NAME"
    log_info "  User: $DB_USER"
    log_info "  Password: [hidden - ${#DB_PASSWORD} characters]"
    
    if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
        log_error "Essential database credentials not found in .env file"
        return 1
    fi
    
    return 0
}

# Setup PostgreSQL authentication
setup_postgresql_auth() {
    log "Setting up PostgreSQL authentication..."
    
    # Find PostgreSQL config directory
    local pg_hba_file=""
    for version_dir in /etc/postgresql/*/main; do
        if [[ -f "$version_dir/pg_hba.conf" ]]; then
            pg_hba_file="$version_dir/pg_hba.conf"
            break
        fi
    done
    
    if [[ -z "$pg_hba_file" ]]; then
        log_error "PostgreSQL configuration not found. Is PostgreSQL installed?"
        return 1
    fi
    
    log_info "Found PostgreSQL config: $pg_hba_file"
    
    # Backup original config
    if [[ ! -f "$pg_hba_file.backup" ]]; then
        cp "$pg_hba_file" "$pg_hba_file.backup"
        log_success "Created backup of pg_hba.conf"
    fi
    
    # Update authentication method from peer to md5 for local connections
    if grep -q "^local.*all.*all.*peer" "$pg_hba_file"; then
        sed -i 's/^local\s\+all\s\+all\s\+peer/local   all             all                                     md5/' "$pg_hba_file"
        log_success "Updated PostgreSQL authentication to use md5"
        
        # Restart PostgreSQL
        log "Restarting PostgreSQL service..."
        if systemctl restart postgresql; then
            log_success "PostgreSQL restarted successfully"
            sleep 2  # Give PostgreSQL time to start
        else
            log_error "Failed to restart PostgreSQL"
            return 1
        fi
    else
        log_info "PostgreSQL authentication already configured correctly"
    fi
    
    return 0
}

# Create system user
create_snailycad_user() {
    log "Setting up snailycad system user..."
    
    if id "$DB_USER" &>/dev/null; then
        log_info "System user '$DB_USER' already exists"
    else
        log "Creating system user: $DB_USER"
        if useradd -m -s /bin/bash "$DB_USER" 2>/dev/null; then
            log_success "Created system user: $DB_USER"
        else
            log_error "Failed to create system user: $DB_USER"
            return 1
        fi
    fi
    
    # Ensure home directory exists with correct permissions
    if [[ ! -d "/home/$DB_USER" ]]; then
        mkdir -p "/home/$DB_USER"
    fi
    
    chown "$DB_USER:$DB_USER" "/home/$DB_USER"
    chmod 755 "/home/$DB_USER"
    
    log_success "Home directory configured: /home/$DB_USER"
    return 0
}

# Setup database user
setup_database_user() {
    log "Setting up PostgreSQL database user..."
    
    # Check if user exists
    if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" 2>/dev/null | grep -q 1; then
        log_info "Database user '$DB_USER' already exists"
        
        # Update password
        if su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH PASSWORD '$DB_PASSWORD';\"" >/dev/null 2>&1; then
            log_success "Updated password for database user: $DB_USER"
        else
            log_warning "Could not update password for database user"
        fi
    else
        log "Creating database user: $DB_USER"
        if su - postgres -c "psql -c \"CREATE USER \\\"$DB_USER\\\" WITH PASSWORD '$DB_PASSWORD' CREATEDB;\"" >/dev/null 2>&1; then
            log_success "Created database user: $DB_USER"
        else
            log_error "Failed to create database user: $DB_USER"
            return 1
        fi
    fi
    
    return 0
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    local missing_deps=()
    local required_cmds=("psql" "createdb" "dropdb" "pg_restore" "tar" "gunzip")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_warning "Missing dependencies: ${missing_deps[*]}"
        
        if command -v apt-get &>/dev/null; then
            log "Installing PostgreSQL and required packages..."
            apt-get update -qq
            apt-get install -y postgresql postgresql-contrib tar gzip
            log_success "Dependencies installed"
        else
            log_error "Cannot automatically install dependencies. Please install PostgreSQL manually."
            return 1
        fi
    else
        log_success "All dependencies are available"
    fi
    
    # Ensure PostgreSQL is running
    if systemctl is-active --quiet postgresql; then
        log_success "PostgreSQL service is running"
    else
        log "Starting PostgreSQL service..."
        systemctl start postgresql
        sleep 2
        log_success "PostgreSQL service started"
    fi
    
    return 0
}

# Find backup archive
find_backup_archive() {
    log "Searching for backup archive in $BACKUP_SEARCH_DIR..."
    
    local backup_files=()
    
    # Find all .tar.gz files
    while IFS= read -r file; do
        backup_files+=("$file")
    done < <(find "$BACKUP_SEARCH_DIR" -maxdepth 2 -type f -name "*.tar.gz" 2>/dev/null)
    
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        log_error "No backup archives (*.tar.gz) found in $BACKUP_SEARCH_DIR"
        return 1
    fi
    
    # Sort by modification time and get the most recent
    local latest_backup
    latest_backup=$(printf '%s\n' "${backup_files[@]}" | xargs ls -t | head -n1)
    
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        log_success "Found backup archive: $latest_backup"
        echo "$latest_backup"
        return 0
    else
        log_error "Could not determine latest backup file"
        return 1
    fi
}

# Extract backup archive
extract_backup_archive() {
    local archive_path="$1"
    
    log "Creating temporary directory: $TEMP_DIR"
    if ! mkdir -p "$TEMP_DIR"; then
        log_error "Failed to create temporary directory"
        return 1
    fi
    
    log "Extracting archive..."
    if tar -xzf "$archive_path" -C "$TEMP_DIR" 2>>"$LOG_FILE"; then
        log_success "Archive extracted successfully"
        
        # Show what was extracted
        log_info "Extracted files:"
        find "$TEMP_DIR" -type f | head -10 | while read -r file; do
            log_info "  - $(basename "$file")"
        done
        
        return 0
    else
        log_error "Failed to extract archive"
        return 1
    fi
}

# Locate backup files within extracted archive
locate_backup_files() {
    log "Locating backup files in extracted archive..."
    
    # Find .env backup file
    local env_file
    env_file=$(find "$TEMP_DIR" -type f \( -name "env_backup_*" -o -name ".env" -o -name "*.env" \) | head -n1)
    
    if [[ -z "$env_file" || ! -f "$env_file" ]]; then
        log_error "No environment backup file found in archive"
        return 1
    fi
    
    log_success "ENV file found: $(basename "$env_file")"
    
    # Find database dump file
    local db_dump
    db_dump=$(find "$TEMP_DIR" -type f \( -name "db_backup_*" -o -name "*.sql" -o -name "*.dump" \) | head -n1)
    
    if [[ -z "$db_dump" || ! -f "$db_dump" ]]; then
        log_error "No database dump file found in archive"
        return 1
    fi
    
    local dump_size
    dump_size=$(du -h "$db_dump" | cut -f1)
    log_success "Database dump found: $(basename "$db_dump") ($dump_size)"
    
    # Return both files
    echo "$env_file" "$db_dump"
    return 0
}

# Setup/recreate database
setup_database() {
    log "=== Setting up database ==="
    
    export PGPASSWORD="$DB_PASSWORD"
    
    # Check if database exists
    if su - postgres -c "psql -lqt" 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        log_warning "Database '$DB_NAME' already exists"
        
        echo ""
        read -p "Do you want to DROP the existing database and import fresh data? (yes/no): " -r response
        echo ""
        
        if [[ "$response" != "yes" ]]; then
            log_error "Import cancelled by user"
            return 1
        fi
        
        log_warning "Dropping existing database: $DB_NAME"
        if su - postgres -c "dropdb \"$DB_NAME\"" 2>/dev/null; then
            log_success "Dropped existing database"
        else
            log_error "Failed to drop database"
            return 1
        fi
    fi
    
    # Create fresh database
    log "Creating database: $DB_NAME"
    if su - postgres -c "createdb -O \"$DB_USER\" \"$DB_NAME\"" 2>/dev/null; then
        log_success "Database created successfully"
        return 0
    else
        log_error "Failed to create database"
        return 1
    fi
}

# Import database dump
import_database() {
    local db_dump="$1"
    
    log "=== Importing database dump ==="
    log_info "This may take several minutes depending on the database size..."
    
    export PGPASSWORD="$DB_PASSWORD"
    
    # Determine file type and import accordingly
    if [[ "$db_dump" == *.sql ]]; then
        log "Importing SQL dump..."
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$db_dump" >>"$LOG_FILE" 2>&1; then
            log_success "SQL dump imported successfully"
        else
            log_error "Failed to import SQL dump. Check log file: $LOG_FILE"
            return 1
        fi
    elif [[ "$db_dump" == *.dump ]]; then
        log "Restoring binary dump..."
        if pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v "$db_dump" >>"$LOG_FILE" 2>&1; then
            log_success "Binary dump restored successfully"
        else
            log_error "Failed to restore binary dump. Check log file: $LOG_FILE"
            return 1
        fi
    else
        log_error "Unsupported database dump format: $db_dump"
        return 1
    fi
    
    # Get database size
    local db_size
    db_size=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" 2>/dev/null || echo "unknown")
    log_info "Imported database size: $db_size"
    
    return 0
}

# Restore environment file
restore_env_file() {
    local env_file="$1"
    
    log "=== Restoring environment file ==="
    
    local target_dir="/home/$DB_USER"
    local target_env="$target_dir/.env"
    
    # Ensure directory exists
    mkdir -p "$target_dir"
    chown "$DB_USER:$DB_USER" "$target_dir"
    
    # Copy .env file
    log "Copying .env file to $target_env"
    if cp "$env_file" "$target_env"; then
        chown "$DB_USER:$DB_USER" "$target_env"
        chmod 600 "$target_env"
        log_success "Environment file restored successfully"
        
        # Show preview (first 10 lines, hiding passwords)
        log_info "Environment file preview:"
        head -n 10 "$target_env" | while IFS= read -r line; do
            if [[ "$line" =~ PASSWORD ]]; then
                log_info "  $(echo "$line" | sed 's/=.*/=[hidden]/')"
            else
                log_info "  $line"
            fi
        done
        
        return 0
    else
        log_error "Failed to copy .env file"
        return 1
    fi
}

# Verify import
verify_import() {
    log "=== Verifying import ==="
    
    export PGPASSWORD="$DB_PASSWORD"
    
    # Check table count
    local table_count
    table_count=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
    
    if [[ "$table_count" -gt 0 ]]; then
        log_success "Database verification: Found $table_count tables"
        
        # List some tables
        log_info "Sample tables:"
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT tablename FROM pg_tables WHERE schemaname = 'public' LIMIT 5;" 2>/dev/null | while read -r table; do
            log_info "  - $table"
        done
    else
        log_warning "No tables found in database - import may have failed"
    fi
    
    # Check environment file
    if [[ -f "/home/$DB_USER/.env" && -s "/home/$DB_USER/.env" ]]; then
        log_success "Environment file verified"
    else
        log_warning "Environment file missing or empty"
    fi
    
    return 0
}

# Main function
main() {
    echo ""
    log "==================================================================="
    log "    SnailyCAD Database Import Script"
    log "==================================================================="
    log "Log file: $LOG_FILE"
    echo ""
    
    # Check prerequisites
    check_privileges || exit 1
    check_dependencies || exit 1
    
    # Find and extract backup
    local backup_archive
    backup_archive=$(find_backup_archive) || exit 1
    
    local archive_size
    archive_size=$(du -h "$backup_archive" | cut -f1)
    log_info "Archive size: $archive_size"
    
    extract_backup_archive "$backup_archive" || exit 1
    
    # Locate backup files
    local backup_files
    backup_files=$(locate_backup_files) || exit 1
    
    read -r env_file db_dump <<< "$backup_files"
    
    # Extract credentials
    extract_db_credentials "$env_file" || exit 1
    
    # Setup PostgreSQL
    setup_postgresql_auth || exit 1
    
    # Setup users
    create_snailycad_user || exit 1
    setup_database_user || exit 1
    
    # Setup and import database
    setup_database || exit 1
    import_database "$db_dump" || exit 1
    
    # Restore environment
    restore_env_file "$env_file" || exit 1
    
    # Verify everything
    verify_import
    
    # Final summary
    echo ""
    log "==================================================================="
    log_success "    SnailyCAD Import Completed Successfully!"
    log "==================================================================="
    log ""
    log "Database Details:"
    log "  - Database Name: $DB_NAME"
    log "  - Database User: $DB_USER"
    log "  - Database Host: $DB_HOST:$DB_PORT"
    log "  - Environment File: /home/$DB_USER/.env"
    log ""
    log "Next Steps:"
    log "  1. Review the log file: $LOG_FILE"
    log "  2. Update your application configuration if needed"
    log "  3. Restart your SnailyCAD application"
    log ""
    log "==================================================================="
    echo ""
}

# Run main function
main "$@"
