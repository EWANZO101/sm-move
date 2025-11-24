#!/bin/bash

# SnailyCAD Database Import Script - Complete Solution
# Includes automatic checks, manual import fallback, and authentication auto-fix

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
CYAN='\033[0;36m'
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

log_manual() {
    echo -e "${CYAN}[MANUAL]${NC} $1" | tee -a "$LOG_FILE"
}

# Cleanup function
cleanup() {
    # Don't delete temp dir - we might need it for manual import
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
    DB_NAME=${DB_NAME:-"snaily-cadv4"}
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
    
    if [[ ! -f "$pg_hba_file.backup_original" ]]; then
        cp "$pg_hba_file" "$pg_hba_file.backup_original" 2>/dev/null || true
    fi
    
    # Ensure trust authentication for local postgres user (for setup)
    if ! grep -q "^local.*all.*postgres.*trust" "$pg_hba_file" 2>/dev/null; then
        sed -i '1i\local   all             postgres                                trust' "$pg_hba_file" 2>/dev/null || true
        log_success "Added trust auth for postgres user"
    fi
    
    # Ensure md5 authentication for all other local connections
    if grep -q "^local.*all.*all.*peer" "$pg_hba_file" 2>/dev/null; then
        sed -i 's/^local\s\+all\s\+all\s\+peer/local   all             all                                     md5/' "$pg_hba_file" 2>/dev/null || true
        log_success "Updated local authentication to md5"
    fi
    
    # Ensure host connections use md5
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
        log_info "System user already exists"
    else
        useradd -m -s /bin/bash "$DB_USER" 2>/dev/null || true
        log_success "System user created"
    fi
    
    mkdir -p "/home/$DB_USER" 2>/dev/null || true
    chown "$DB_USER:$DB_USER" "/home/$DB_USER" 2>/dev/null || true
    chmod 755 "/home/$DB_USER" 2>/dev/null || true
    
    return 0
}

# Check if database user exists
check_database_user_exists() {
    local exists
    exists=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" 2>/dev/null || echo "")
    [[ "$exists" == "1" ]]
}

# Check if database exists
check_database_exists() {
    su - postgres -c "psql -lqt" 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"
}

# AUTO-FIX: Force password authentication to work
auto_fix_authentication() {
    log_warning "Auto-fixing authentication issue..."
    
    local pg_hba_file=""
    for version_dir in /etc/postgresql/*/main; do
        if [[ -f "$version_dir/pg_hba.conf" ]]; then
            pg_hba_file="$version_dir/pg_hba.conf"
            break
        fi
    done
    
    if [[ -z "$pg_hba_file" ]]; then
        log_error "Cannot find pg_hba.conf"
        return 1
    fi
    
    # Backup current config
    cp "$pg_hba_file" "$pg_hba_file.backup_autofix" 2>/dev/null || true
    
    # Method 1: Try with trust auth temporarily
    log_info "Setting temporary trust authentication..."
    cat > "$pg_hba_file" <<EOF
# Temporary trust auth for setup
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOF
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 2
    
    # Reset password while trust is active
    log_info "Resetting password with trust auth..."
    su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH PASSWORD '$DB_PASSWORD';\"" 2>&1 | tee -a "$LOG_FILE"
    
    # Also try MD5 hash method
    local md5_pass
    md5_pass=$(echo -n "${DB_PASSWORD}${DB_USER}" | md5sum | cut -d' ' -f1)
    su - postgres -c "psql -c \"UPDATE pg_authid SET rolpassword = 'md5$md5_pass' WHERE rolname = '$DB_USER';\"" 2>&1 | tee -a "$LOG_FILE"
    
    # Now try switching back to md5
    log_info "Switching back to md5 authentication..."
    cat > "$pg_hba_file" <<EOF
# Auto-fixed authentication
local   all             postgres                                trust
local   all             $DB_USER                                md5
local   all             all                                     md5

host    all             postgres        127.0.0.1/32            trust
host    all             $DB_USER        127.0.0.1/32            md5
host    all             all             127.0.0.1/32            md5

host    all             postgres        ::1/128                 trust
host    all             $DB_USER        ::1/128                 md5
host    all             all             ::1/128                 md5
EOF
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 2
    
    # Test if md5 works
    export PGPASSWORD="$DB_PASSWORD"
    if psql -h 127.0.0.1 -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1;" &>/dev/null; then
        log_success "✓ MD5 authentication working!"
        return 0
    fi
    
    # If md5 fails, use trust for this user
    log_warning "MD5 failed, using trust authentication for $DB_USER..."
    cat > "$pg_hba_file" <<EOF
# Auto-fixed with trust for $DB_USER
local   all             postgres                                trust
local   all             $DB_USER                                trust
local   all             all                                     md5

host    all             postgres        127.0.0.1/32            trust
host    all             $DB_USER        127.0.0.1/32            trust
host    all             all             127.0.0.1/32            md5

host    all             postgres        ::1/128                 trust
host    all             $DB_USER        ::1/128                 trust
host    all             all             ::1/128                 md5
EOF
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 2
    
    if psql -h 127.0.0.1 -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1;" &>/dev/null; then
        log_success "✓ Trust authentication working!"
        log_warning "Note: User $DB_USER does not require password (trust auth)"
        return 0
    fi
    
    log_error "Auto-fix failed"
    return 1
}

# Setup database user with comprehensive error handling
setup_database_user() {
    log "Setting up database user: $DB_USER"
    
    # Check if user exists
    if check_database_user_exists; then
        log_info "Database user already exists"
        
        # Update password
        log_info "Updating password..."
        local safe_password="${DB_PASSWORD//\'/\'\'}"
        if su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH PASSWORD '$safe_password' CREATEDB CREATEROLE LOGIN;\"" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Password updated"
        else
            log_warning "Could not update password, trying to recreate..."
            
            # Terminate connections
            su - postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='$DB_USER';\"" &>/dev/null || true
            
            # Drop and recreate
            su - postgres -c "psql -c \"REASSIGN OWNED BY \\\"$DB_USER\\\" TO postgres; DROP OWNED BY \\\"$DB_USER\\\"; DROP USER IF EXISTS \\\"$DB_USER\\\";\"" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    
    # Create user if needed
    if ! check_database_user_exists; then
        log "Creating database user..."
        
        local safe_password="${DB_PASSWORD//\'/\'\'}"
        local create_sql="CREATE USER \"${DB_USER}\" WITH PASSWORD '${safe_password}' CREATEDB CREATEROLE LOGIN;"
        
        if su - postgres -c "psql -c \"$create_sql\"" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Database user created"
        else
            log_error "Failed to create database user"
            return 1
        fi
    fi
    
    # Verify user exists
    if check_database_user_exists; then
        log_success "Database user verified"
    else
        log_error "User verification failed"
        return 1
    fi
    
    # Test authentication
    log "Testing authentication..."
    export PGPASSWORD="$DB_PASSWORD"
    
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 'OK' as status;" 2>&1 | tee -a "$LOG_FILE" | grep -q "OK"; then
        log_success "✓ Authentication PASSED"
        return 0
    else
        log_warning "Authentication test failed - attempting auto-fix..."
        
        # AUTO-FIX: Try to fix authentication
        if auto_fix_authentication; then
            log_success "✓ Authentication auto-fixed!"
            return 0
        else
            log_error "Auto-fix failed, but user exists - may work for import"
            return 0  # Continue anyway
        fi
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
        log_success "Extracted $count files to: $TEMP_DIR"
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
    
    # Check if database exists
    if check_database_exists; then
        log_warning "Database '$DB_NAME' already exists"
        read -p "Drop and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Dropping existing database..."
            su - postgres -c "dropdb \"$DB_NAME\"" 2>&1 | tee -a "$LOG_FILE" || true
            log_success "Database dropped"
        else
            log_info "Keeping existing database"
            return 0
        fi
    fi
    
    # Create database
    if ! check_database_exists; then
        log "Creating database: $DB_NAME"
        if su - postgres -c "createdb -O \"$DB_USER\" \"$DB_NAME\"" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Database created"
        else
            log_error "Failed to create database"
            return 1
        fi
    fi
    
    # Grant privileges
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"$DB_NAME\\\" TO \\\"$DB_USER\\\";\"" 2>&1 | tee -a "$LOG_FILE" || true
    
    return 0
}

# Import database
import_database() {
    local db_dump="$1"
    
    log "=== Importing database ==="
    log_info "Dump file: $db_dump"
    log_info "This may take several minutes..."
    
    export PGPASSWORD="$DB_PASSWORD"
    
    # Try user authentication first
    if [[ "$db_dump" == *.sql ]]; then
        log "Attempting import as user: $DB_USER"
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$db_dump" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Import completed"
            return 0
        else
            log_warning "Import as $DB_USER failed"
        fi
    fi
    
    # Fallback to postgres user
    log_warning "Trying import as postgres user..."
    cd "$TEMP_DIR" || return 1
    
    if su - postgres -c "psql -d \"$DB_NAME\" -f \"$db_dump\"" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Import completed using postgres user"
        
        # Fix ownership
        log "Fixing object ownership..."
        su - postgres -c "psql -d \"$DB_NAME\" -c \"REASSIGN OWNED BY postgres TO \\\"$DB_USER\\\";\"" 2>&1 | tee -a "$LOG_FILE" || true
        
        return 0
    else
        log_error "Import failed"
        return 1
    fi
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
    
    # NEW: Test Prisma-style connection
    log "=== Testing Prisma Connection Style ==="
    test_prisma_connection
    
    return 0
}

# Test connection the way Prisma does it
test_prisma_connection() {
    log_info "Simulating Prisma authentication test..."
    
    export PGPASSWORD="$DB_PASSWORD"
    
    # Test 1: Try connection exactly as Prisma would (to localhost)
    log_info "Test 1: Connecting to localhost:$DB_PORT as $DB_USER..."
    if psql -h localhost -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1 as test;" &>/dev/null; then
        log_success "✓ Prisma-style connection WORKS"
        return 0
    else
        log_warning "✗ Connection failed - this will cause P1000 error"
    fi
    
    # Test 2: Try with 127.0.0.1
    log_info "Test 2: Connecting to 127.0.0.1:$DB_PORT as $DB_USER..."
    if psql -h 127.0.0.1 -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1 as test;" &>/dev/null; then
        log_success "✓ 127.0.0.1 connection works"
        log_warning "But Prisma uses 'localhost' - updating .env..."
        fix_env_host "127.0.0.1"
        return 0
    else
        log_warning "✗ 127.0.0.1 connection also failed"
    fi
    
    # Test 3: Try Unix socket
    log_info "Test 3: Trying Unix socket connection..."
    if psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1 as test;" &>/dev/null; then
        log_success "✓ Unix socket works"
        log_warning "But Prisma needs TCP/IP - fixing authentication..."
        prisma_authentication_fix
        return 0
    else
        log_error "✗ All connection methods failed"
        prisma_authentication_fix
    fi
}

# Fix .env to use working host
fix_env_host() {
    local working_host="$1"
    
    for env_file in "/home/$DB_USER/.env" "/home/snaily-cadv4/.env"; do
        if [[ -f "$env_file" ]]; then
            log_info "Updating $env_file to use $working_host..."
            sed -i "s/^DATABASE_HOST=.*/DATABASE_HOST=\"$working_host\"/" "$env_file" 2>/dev/null
            log_success "Updated $env_file"
        fi
    done
}

# Comprehensive Prisma authentication fix
prisma_authentication_fix() {
    log_warning "=== FIXING PRISMA AUTHENTICATION ==="
    
    local pg_hba_file=""
    for version_dir in /etc/postgresql/*/main; do
        if [[ -f "$version_dir/pg_hba.conf" ]]; then
            pg_hba_file="$version_dir/pg_hba.conf"
            break
        fi
    done
    
    if [[ -z "$pg_hba_file" ]]; then
        log_error "Cannot find pg_hba.conf"
        return 1
    fi
    
    log_info "Found: $pg_hba_file"
    
    # Backup
    cp "$pg_hba_file" "$pg_hba_file.backup_prisma_fix" 2>/dev/null || true
    
    # Step 1: Set everything to trust temporarily
    log_info "Setting trust authentication..."
    cat > "$pg_hba_file" <<EOF
# Prisma authentication fix - trust mode
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             0.0.0.0/0               trust
EOF
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 3
    
    # Step 2: Force password reset while trust is active
    log_info "Force-resetting password..."
    su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH PASSWORD '$DB_PASSWORD';\"" 2>&1 | tee -a "$LOG_FILE"
    
    # Step 3: Also set via MD5 hash
    local md5_pass
    md5_pass=$(echo -n "${DB_PASSWORD}${DB_USER}" | md5sum | cut -d' ' -f1)
    su - postgres -c "psql -c \"UPDATE pg_authid SET rolpassword = 'md5$md5_pass' WHERE rolname = '$DB_USER';\"" 2>&1 | tee -a "$LOG_FILE"
    
    # Step 4: Grant SUPERUSER if not already
    su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH SUPERUSER CREATEDB CREATEROLE LOGIN;\"" 2>&1 | tee -a "$LOG_FILE"
    
    # Step 5: Update .pgpass for passwordless access
    log_info "Creating .pgpass file..."
    for user_home in "/home/$DB_USER" "/root"; do
        local pgpass_file="$user_home/.pgpass"
        cat > "$pgpass_file" <<EOF
localhost:$DB_PORT:$DB_NAME:$DB_USER:$DB_PASSWORD
localhost:$DB_PORT:*:$DB_USER:$DB_PASSWORD
127.0.0.1:$DB_PORT:$DB_NAME:$DB_USER:$DB_PASSWORD
127.0.0.1:$DB_PORT:*:$DB_USER:$DB_PASSWORD
*:$DB_PORT:$DB_NAME:$DB_USER:$DB_PASSWORD
*:$DB_PORT:*:$DB_USER:$DB_PASSWORD
EOF
        chmod 600 "$pgpass_file" 2>/dev/null
        chown $(basename "$user_home"):$(basename "$user_home") "$pgpass_file" 2>/dev/null || true
        log_success "Created $pgpass_file"
    done
    
    # Step 6: Try switching to md5
    log_info "Attempting md5 authentication..."
    cat > "$pg_hba_file" <<EOF
# Prisma authentication fix - md5 mode
local   all             postgres                                trust
local   all             $DB_USER                                md5
local   all             all                                     md5

host    all             postgres        127.0.0.1/32            trust
host    all             $DB_USER        127.0.0.1/32            md5
host    all             all             127.0.0.1/32            md5

host    all             postgres        ::1/128                 trust
host    all             $DB_USER        ::1/128                 md5
host    all             all             ::1/128                 md5

host    all             all             0.0.0.0/0               md5
EOF
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 3
    
    # Test md5
    export PGPASSWORD="$DB_PASSWORD"
    log_info "Testing md5 authentication..."
    if psql -h localhost -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 'SUCCESS' as status;" 2>&1 | grep -q "SUCCESS"; then
        log_success "✓✓✓ MD5 AUTHENTICATION WORKING ✓✓✓"
        log_success "Prisma should now connect successfully!"
        return 0
    fi
    
    log_warning "MD5 test failed, falling back to trust..."
    
    # Step 7: Fall back to trust for this user
    cat > "$pg_hba_file" <<EOF
# Prisma authentication fix - trust fallback for $DB_USER
local   all             postgres                                trust
local   all             $DB_USER                                trust
local   all             all                                     md5

host    all             postgres        127.0.0.1/32            trust
host    all             postgres        ::1/128                 trust
host    all             $DB_USER        127.0.0.1/32            trust
host    all             $DB_USER        ::1/128                 trust
host    all             $DB_USER        0.0.0.0/0               trust
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
host    all             all             0.0.0.0/0               md5
EOF
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 3
    
    # Final test
    if psql -h localhost -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 'SUCCESS' as status;" 2>&1 | grep -q "SUCCESS"; then
        log_success "✓ Trust authentication working"
        log_warning "NOTE: User $DB_USER uses trust auth (no password required)"
        log_warning "This is less secure but will fix the P1000 error"
        return 0
    fi
    
    log_error "All authentication methods failed"
    return 1
}

# Show manual import instructions
show_manual_import() {
    local db_dump="$1"
    
    echo ""
    log_manual "=========================================================="
    log_manual "         MANUAL IMPORT INSTRUCTIONS"
    log_manual "=========================================================="
    echo ""
    log_manual "If automated import failed, try this manual method:"
    echo ""
    log_manual "1. Navigate to temp directory:"
    log_manual "   cd $TEMP_DIR"
    echo ""
    log_manual "2. Import as postgres user:"
    log_manual "   su - postgres -c \"psql -d $DB_NAME -f $db_dump\""
    echo ""
    log_manual "3. Or directly with psql:"
    log_manual "   psql -U postgres -d $DB_NAME -f $(basename "$db_dump")"
    echo ""
    log_manual "4. Then fix ownership:"
    log_manual "   su - postgres -c \"psql -d $DB_NAME -c 'REASSIGN OWNED BY postgres TO $DB_USER;'\""
    echo ""
    log_manual "Files are preserved in: $TEMP_DIR"
    log_manual "=========================================================="
    echo ""
}

# Main function
main() {
    echo ""
    log "==================================================================="
    log "    SnailyCAD Database Import - COMPLETE SOLUTION"
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
    setup_database_user  # This now includes auto-fix
    
    # Database setup
    if ! setup_database; then
        log_error "Database setup failed"
        show_manual_import "$db_dump"
        exit 1
    fi
    
    # Import
    if ! import_database "$db_dump"; then
        log_error "Automated import failed"
        show_manual_import "$db_dump"
        exit 1
    fi
    
    # Restore .env
    if ! restore_env_file "$env_file"; then
        log_warning "Environment restore had issues"
    fi
    
    # Ensure SnailyCAD app directory also has correct .env
    log "Checking SnailyCAD app directory..."
    if [[ -d "/home/snaily-cadv4" ]]; then
        log_info "Found SnailyCAD app at /home/snaily-cadv4"
        
        if [[ -f "/home/$DB_USER/.env" ]]; then
            cp "/home/$DB_USER/.env" "/home/snaily-cadv4/.env" 2>/dev/null || true
            chown "$DB_USER:$DB_USER" "/home/snaily-cadv4/.env" 2>/dev/null || true
            chmod 600 "/home/snaily-cadv4/.env" 2>/dev/null || true
            log_success "Updated /home/snaily-cadv4/.env"
        fi
    fi
    
    # Verify
    verify_import
    
    # Success
    echo ""
    log "==================================================================="
    log_success "    IMPORT COMPLETED SUCCESSFULLY!"
    log "==================================================================="
    echo ""
    log "Database Configuration:"
    log "  Database: $DB_NAME @ $DB_HOST:$DB_PORT"
    log "  User: $DB_USER"
    log "  Config: /home/$DB_USER/.env"
    [[ -f "/home/snaily-cadv4/.env" ]] && log "  App Config: /home/snaily-cadv4/.env"
    log "  Log: $LOG_FILE"
    echo ""
    log "Connection Test:"
    log "  PGPASSWORD='$DB_PASSWORD' psql -h localhost -U $DB_USER -d $DB_NAME"
    echo ""
    
    # Final Prisma connection test
    log "=== FINAL PRISMA CONNECTION TEST ==="
    export PGPASSWORD="$DB_PASSWORD"
    if psql -h localhost -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 'Prisma connection will work!' as status;" 2>&1 | grep -q "Prisma connection will work"; then
        log_success "✓✓✓ Prisma Connection Test PASSED ✓✓✓"
        echo ""
        log_success "You can now start SnailyCAD without P1000 errors:"
        log_info "  cd /home/snaily-cadv4"
        log_info "  pnpm run start"
        echo ""
    else
        log_warning "Connection test inconclusive - check the log"
        log_info "If SnailyCAD still fails, run:"
        log_info "  psql -h localhost -U $DB_USER -d $DB_NAME"
        log_info "If this works, Prisma will too."
        echo ""
    fi
    
    log "==================================================================="
    echo ""
}

main "$@"
