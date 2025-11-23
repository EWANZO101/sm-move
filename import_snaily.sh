#!/bin/bash

# SnailyCAD Database Import Script - Enhanced Error Handling
# This version includes detailed diagnostics

set -uo pipefail

# Configuration
LOG_FILE="/tmp/snaily_import_$(date +%Y%m%d_%H%M%S).log"
BACKUP_SEARCH_DIR="/home"
TEMP_DIR="/tmp/snaily_import_temp_$$"
RESULT_FILE="/tmp/snaily_result_$$"

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
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    rm -f "$RESULT_FILE" 2>/dev/null || true
}

trap cleanup EXIT

# Extract database credentials from .env file
extract_db_credentials() {
    local env_file="$1"
    
    log "Extracting database credentials from .env file..."
    
    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        return 1
    fi
    
    # Extract credentials
    DB_HOST=$(grep -E '^DATABASE_HOST=' "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' | tr -d '[:space:]' || echo "")
    DB_PORT=$(grep -E '^DATABASE_PORT=' "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' | tr -d '[:space:]' || echo "")
    DB_NAME=$(grep -E '^DATABASE_NAME=' "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' | tr -d '[:space:]' || echo "")
    DB_USER=$(grep -E '^DATABASE_USER=' "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' | tr -d '[:space:]' || echo "")
    DB_PASSWORD=$(grep -E '^DATABASE_PASSWORD=' "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/^["'\'']*//;s/["'\'']*$//' || echo "")
    
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
    log_info "  Password: [${#DB_PASSWORD} characters]"
    
    if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
        log_error "Essential database credentials not found"
        return 1
    fi
    
    return 0
}

# Setup PostgreSQL authentication
setup_postgresql_auth() {
    log "Setting up PostgreSQL authentication..."
    
    local pg_hba_file=""
    for version_dir in /etc/postgresql/*/main; do
        if [[ -f "$version_dir/pg_hba.conf" ]]; then
            pg_hba_file="$version_dir/pg_hba.conf"
            break
        fi
    done
    
    if [[ -z "$pg_hba_file" ]]; then
        log_warning "PostgreSQL config not found, continuing..."
        return 0
    fi
    
    log_info "Found: $pg_hba_file"
    
    if [[ ! -f "$pg_hba_file.backup" ]]; then
        cp "$pg_hba_file" "$pg_hba_file.backup" 2>/dev/null || true
    fi
    
    # Ensure md5 authentication for all connections
    if grep -q "^local.*all.*all.*peer" "$pg_hba_file" 2>/dev/null; then
        sed -i.bak 's/^local\s\+all\s\+all\s\+peer/local   all             all                                     md5/' "$pg_hba_file" 2>/dev/null || true
        log_success "Updated local authentication to md5"
    fi
    
    # Also ensure host connections use md5
    if ! grep -q "^host.*all.*all.*127.0.0.1/32.*md5" "$pg_hba_file" 2>/dev/null; then
        echo "host    all             all             127.0.0.1/32            md5" >> "$pg_hba_file" 2>/dev/null || true
        log_success "Added host authentication rule"
    fi
    
    systemctl restart postgresql 2>/dev/null || true
    sleep 3
    log_success "PostgreSQL restarted"
    
    return 0
}

# Create system user
create_snailycad_user() {
    log "Setting up system user: $DB_USER"
    
    if id "$DB_USER" &>/dev/null; then
        log_info "User already exists"
    else
        useradd -m -s /bin/bash "$DB_USER" 2>/dev/null || true
        log_success "User created"
    fi
    
    mkdir -p "/home/$DB_USER" 2>/dev/null || true
    chown "$DB_USER:$DB_USER" "/home/$DB_USER" 2>/dev/null || true
    chmod 755 "/home/$DB_USER" 2>/dev/null || true
    
    return 0
}

# Setup database user with enhanced error handling
setup_database_user() {
    log "Setting up database user: $DB_USER"
    
    # First, let's check if we can connect as postgres
    log_info "Testing postgres connection..."
    if ! su - postgres -c "psql -c 'SELECT version();'" &>/dev/null; then
        log_error "Cannot connect to PostgreSQL as postgres user"
        return 1
    fi
    log_success "PostgreSQL connection OK"
    
    # Check if user exists
    log_info "Checking if user exists..."
    local user_exists
    user_exists=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" 2>/dev/null || echo "")
    
    if [[ "$user_exists" == "1" ]]; then
        log_info "User exists, dropping..."
        
        # Terminate any connections from this user
        su - postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='$DB_USER';\"" &>/dev/null || true
        
        # Try to drop user - if it fails, it might own objects
        if ! su - postgres -c "psql -c \"DROP USER IF EXISTS \\\"$DB_USER\\\";\"" 2>&1 | tee -a "$LOG_FILE"; then
            log_warning "User might own database objects, trying to reassign..."
            
            # List databases owned by user
            su - postgres -c "psql -c \"SELECT datname FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$DB_USER');\"" 2>&1 | tee -a "$LOG_FILE"
            
            # Reassign ownership and drop
            su - postgres -c "psql -c \"REASSIGN OWNED BY \\\"$DB_USER\\\" TO postgres; DROP OWNED BY \\\"$DB_USER\\\"; DROP USER IF EXISTS \\\"$DB_USER\\\";\"" 2>&1 | tee -a "$LOG_FILE"
        fi
        log_success "User dropped"
    else
        log_info "User doesn't exist yet"
    fi
    
    # Now create the user
    log "Creating database user..."
    
    # Escape password for SQL (replace ' with '')
    local safe_password="${DB_PASSWORD//\'/\'\'}"
    
    # Create user using heredoc to avoid quoting issues
    local create_sql="CREATE USER \"${DB_USER}\" WITH PASSWORD '${safe_password}' CREATEDB CREATEROLE LOGIN;"
    
    log_info "Executing: CREATE USER \"${DB_USER}\" WITH PASSWORD '[HIDDEN]' CREATEDB CREATEROLE LOGIN;"
    
    if su - postgres -c "psql -c \"$create_sql\"" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Database user created"
    else
        log_error "Failed to create database user - see log above"
        return 1
    fi
    
    # Verify user was created
    log_info "Verifying user creation..."
    local verify
    verify=$(su - postgres -c "psql -tAc \"SELECT rolname, rolcanlogin, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname='$DB_USER';\"" 2>/dev/null)
    
    if [[ -n "$verify" ]]; then
        log_success "User verified: $verify"
    else
        log_error "User not found after creation"
        return 1
    fi
    
    # Grant privileges
    log_info "Granting privileges..."
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE postgres TO \\\"$DB_USER\\\";\"" 2>&1 | tee -a "$LOG_FILE"
    
    # Test authentication
    log "Testing authentication..."
    export PGPASSWORD="$DB_PASSWORD"
    
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 'Authentication successful!' as test;" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "✓ Authentication PASSED"
        return 0
    else
        log_error "✗ Authentication FAILED"
        log_info "Testing with alternative methods..."
        
        # Try without host specification (local socket)
        log_info "Trying local socket connection..."
        if psql -U "$DB_USER" -d postgres -c "SELECT 1;" 2>&1 | tee -a "$LOG_FILE"; then
            log_warning "Local socket works but TCP doesn't"
        fi
        
        return 1
    fi
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    local missing_deps=()
    for cmd in psql createdb dropdb pg_restore tar gunzip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_warning "Missing: ${missing_deps[*]}"
        if command -v apt-get &>/dev/null; then
            log "Installing packages..."
            apt-get update -qq 2>/dev/null || true
            apt-get install -y postgresql postgresql-contrib tar gzip 2>/dev/null || true
        fi
    fi
    
    log_success "All dependencies available"
    
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        log_success "PostgreSQL is running"
    else
        systemctl start postgresql 2>/dev/null || true
        sleep 2
    fi
    
    return 0
}

# Find backup archive
find_backup_archive() {
    local backup_files=()
    
    while IFS= read -r file; do
        [[ -f "$file" ]] && backup_files+=("$file")
    done < <(find "$BACKUP_SEARCH_DIR" -maxdepth 2 -type f -name "*.tar.gz" 2>/dev/null)
    
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        return 1
    fi
    
    local latest_backup="" latest_time=0
    for file in "${backup_files[@]}"; do
        local file_time
        file_time=$(stat -c %Y "$file" 2>/dev/null || echo "0")
        if [[ "$file_time" -gt "$latest_time" ]]; then
            latest_time="$file_time"
            latest_backup="$file"
        fi
    done
    
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        echo "$latest_backup" > "$RESULT_FILE"
        return 0
    fi
    
    return 1
}

# Extract backup archive
extract_backup_archive() {
    local archive_path="$1"
    
    log "Extracting: $(basename "$archive_path")"
    
    mkdir -p "$TEMP_DIR" 2>/dev/null || {
        log_error "Failed to create temp directory"
        return 1
    }
    
    if tar -xzf "$archive_path" -C "$TEMP_DIR" 2>>"$LOG_FILE"; then
        local count
        count=$(find "$TEMP_DIR" -type f 2>/dev/null | wc -l)
        log_success "Extracted $count files"
        return 0
    else
        log_error "Extraction failed"
        return 1
    fi
}

# Locate backup files
locate_backup_files() {
    local env_file db_dump
    
    env_file=$(find "$TEMP_DIR" -type f \( -name "env_backup_*" -o -name ".env" -o -name "*.env" \) 2>/dev/null | head -n1)
    [[ -z "$env_file" || ! -f "$env_file" ]] && return 1
    
    db_dump=$(find "$TEMP_DIR" -type f \( -name "db_backup_*" -o -name "*.sql" -o -name "*.dump" \) 2>/dev/null | head -n1)
    [[ -z "$db_dump" || ! -f "$db_dump" ]] && return 1
    
    echo "$env_file|$db_dump" > "$RESULT_FILE"
    return 0
}

# Setup database
setup_database() {
    log "=== Setting up database ==="
    
    export PGPASSWORD="$DB_PASSWORD"
    
    if su - postgres -c "psql -lqt" 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        log_warning "Database exists, dropping..."
        su - postgres -c "dropdb \"$DB_NAME\"" 2>/dev/null || true
        log_success "Dropped existing database"
    fi
    
    log "Creating database: $DB_NAME"
    if su - postgres -c "createdb -O \"$DB_USER\" \"$DB_NAME\"" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Database created"
        
        # Grant all privileges
        su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"$DB_NAME\\\" TO \\\"$DB_USER\\\";\"" 2>&1 | tee -a "$LOG_FILE"
        
        return 0
    else
        log_error "Failed to create database"
        return 1
    fi
}

# Import database
import_database() {
    local db_dump="$1"
    
    log "=== Importing database ==="
    log_info "This may take several minutes..."
    
    export PGPASSWORD="$DB_PASSWORD"
    
    if [[ "$db_dump" == *.sql ]]; then
        log "Importing SQL dump..."
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$db_dump" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Import completed"
        else
            log_error "Import failed - check log above"
            return 1
        fi
    elif [[ "$db_dump" == *.dump ]]; then
        log "Restoring binary dump..."
        if pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" "$db_dump" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Restore completed"
        else
            log_error "Restore failed - check log above"
            return 1
        fi
    else
        log_error "Unsupported format: $db_dump"
        return 1
    fi
    
    local db_size
    db_size=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" 2>/dev/null || echo "unknown")
    log_info "Database size: $db_size"
    
    return 0
}

# Restore environment file
restore_env_file() {
    local env_file="$1"
    
    log "=== Restoring .env file ==="
    
    local target_dir="/home/$DB_USER"
    local target_env="$target_dir/.env"
    
    mkdir -p "$target_dir" 2>/dev/null || true
    chown "$DB_USER:$DB_USER" "$target_dir" 2>/dev/null || true
    
    if cp "$env_file" "$target_env" 2>/dev/null; then
        chown "$DB_USER:$DB_USER" "$target_env" 2>/dev/null || true
        chmod 600 "$target_env" 2>/dev/null || true
        log_success "Environment file restored to: $target_env"
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
    
    local table_count
    table_count=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
    
    if [[ "$table_count" -gt 0 ]]; then
        log_success "Found $table_count tables"
        
        log_info "Sample tables:"
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT tablename FROM pg_tables WHERE schemaname = 'public' LIMIT 5;" 2>/dev/null | while read -r table; do
            [[ -n "$table" ]] && log_info "  - $table"
        done
    else
        log_warning "No tables found"
    fi
    
    if [[ -f "/home/$DB_USER/.env" && -s "/home/$DB_USER/.env" ]]; then
        log_success "Environment file verified"
    else
        log_warning "Environment file issue"
    fi
    
    return 0
}

# Main function
main() {
    echo ""
    log "==================================================================="
    log "    SnailyCAD Database Import - ENHANCED DIAGNOSTICS"
    log "==================================================================="
    log "Log: $LOG_FILE"
    log_info "Running as: $(whoami)"
    echo ""
    
    check_dependencies
    
    # Find backup
    log "Searching for backup in: $BACKUP_SEARCH_DIR"
    if find_backup_archive; then
        local backup_archive
        backup_archive=$(cat "$RESULT_FILE")
        log_success "Found: $backup_archive"
        
        local size
        size=$(du -h "$backup_archive" 2>/dev/null | cut -f1 || echo "unknown")
        log_info "Size: $size"
    else
        log_error "No backup archive found"
        exit 1
    fi
    
    # Extract
    if ! extract_backup_archive "$backup_archive"; then
        exit 1
    fi
    
    # Locate files
    if locate_backup_files; then
        local env_file db_dump
        IFS='|' read -r env_file db_dump < "$RESULT_FILE"
        
        log_success "ENV: $(basename "$env_file")"
        local dump_size
        dump_size=$(du -h "$db_dump" 2>/dev/null | cut -f1 || echo "unknown")
        log_success "DB dump: $(basename "$db_dump") ($dump_size)"
    else
        log_error "Could not find backup files"
        exit 1
    fi
    
    # Extract credentials
    if ! extract_db_credentials "$env_file"; then
        exit 1
    fi
    
    # Setup
    setup_postgresql_auth
    create_snailycad_user
    
    # THIS IS THE CRITICAL PART with enhanced diagnostics
    if ! setup_database_user; then
        log_error "Database user setup failed - cannot continue"
        log_info "Check the detailed output above for errors"
        exit 1
    fi
    
    # Import
    if ! setup_database; then
        exit 1
    fi
    
    if ! import_database "$db_dump"; then
        exit 1
    fi
    
    if ! restore_env_file "$env_file"; then
        log_warning "Environment restore had issues"
    fi
    
    verify_import
    
    # Success
    echo ""
    log "==================================================================="
    log_success "    IMPORT COMPLETED SUCCESSFULLY!"
    log "==================================================================="
    echo ""
    log "Database: $DB_NAME @ $DB_HOST:$DB_PORT"
    log "User: $DB_USER"
    log "Config: /home/$DB_USER/.env"
    log "Log: $LOG_FILE"
    echo ""
    log "Next steps:"
    log "  1. Test connection: PGPASSWORD='...' psql -h $DB_HOST -U $DB_USER -d $DB_NAME"
    log "  2. Start your application"
    echo ""
    log "==================================================================="
    echo ""
}

main "$@"
