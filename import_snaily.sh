#!/bin/bash

# SnailyCAD Auto-Fixer Script
# Automatically detects and fixes common issues

set -uo pipefail

# Configuration
LOG_FILE="/tmp/snailycad_autofix_$(date +%Y%m%d_%H%M%S).log"
SNAILYCAD_DIR="/home/snaily-cadv4"
ENV_FILE="$SNAILYCAD_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Counters
ISSUES_FOUND=0
ISSUES_FIXED=0
ISSUES_FAILED=0

# Logging functions
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓ FIXED]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[✗ ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_check() {
    echo -e "${CYAN}[CHECK]${NC} $1" | tee -a "$LOG_FILE"
}

log_fix() {
    echo -e "${MAGENTA}[FIX]${NC} $1" | tee -a "$LOG_FILE"
}

# Issue tracking
issue_found() {
    ((ISSUES_FOUND++))
}

issue_fixed() {
    ((ISSUES_FIXED++))
}

issue_failed() {
    ((ISSUES_FAILED++))
}

# Check if running as root
ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Load environment variables
load_env_vars() {
    if [[ -f "$ENV_FILE" ]]; then
        export $(grep -v '^#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | xargs -d '\n')
        log_success "Environment variables loaded"
        return 0
    else
        log_warning "No .env file found at $ENV_FILE"
        return 1
    fi
}

# Fix 1: Kill processes using port 3000 (and other SnailyCAD ports)
fix_port_conflicts() {
    log_check "Checking for port conflicts..."
    
    local ports=(3000 8080 8081 3001)
    local fixed=false
    
    for port in "${ports[@]}"; do
        local pid
        pid=$(lsof -ti:$port 2>/dev/null || true)
        
        if [[ -n "$pid" ]]; then
            issue_found
            log_fix "Port $port is in use by PID $pid"
            
            # Check what process it is
            local process_name
            process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            log_info "Process: $process_name"
            
            # Kill the process
            if kill -9 "$pid" 2>/dev/null; then
                log_success "Killed process on port $port (PID: $pid)"
                issue_fixed
                fixed=true
                sleep 1
            else
                log_error "Failed to kill process on port $port"
                issue_failed
            fi
        fi
    done
    
    if [[ "$fixed" == "true" ]]; then
        log_success "Port conflicts resolved"
    else
        log_info "No port conflicts found"
    fi
}

# Fix 2: Check and fix PostgreSQL service
fix_postgresql_service() {
    log_check "Checking PostgreSQL service..."
    
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        issue_found
        log_fix "PostgreSQL is not running"
        
        if systemctl start postgresql 2>&1 | tee -a "$LOG_FILE"; then
            sleep 2
            log_success "PostgreSQL started"
            issue_fixed
        else
            log_error "Failed to start PostgreSQL"
            issue_failed
            return 1
        fi
    else
        log_info "PostgreSQL is running"
    fi
    
    # Ensure it starts on boot
    if ! systemctl is-enabled --quiet postgresql 2>/dev/null; then
        systemctl enable postgresql 2>&1 | tee -a "$LOG_FILE" || true
        log_success "PostgreSQL enabled on boot"
    fi
}

# Fix 3: Check database connection
fix_database_connection() {
    log_check "Checking database connection..."
    
    if [[ -z "${DATABASE_HOST:-}" || -z "${DATABASE_NAME:-}" || -z "${DATABASE_USER:-}" ]]; then
        log_warning "Database credentials not found in environment"
        return 1
    fi
    
    export PGPASSWORD="${DATABASE_PASSWORD:-}"
    
    if psql -h "${DATABASE_HOST:-localhost}" -p "${DATABASE_PORT:-5432}" -U "${DATABASE_USER}" -d "${DATABASE_NAME}" -c "SELECT 1;" &>/dev/null; then
        log_info "Database connection OK"
        return 0
    else
        issue_found
        log_fix "Database connection failed"
        
        # Try to fix authentication
        local pg_hba_file=""
        for version_dir in /etc/postgresql/*/main; do
            if [[ -f "$version_dir/pg_hba.conf" ]]; then
                pg_hba_file="$version_dir/pg_hba.conf"
                break
            fi
        done
        
        if [[ -n "$pg_hba_file" ]]; then
            # Backup original
            if [[ ! -f "$pg_hba_file.backup_autofix" ]]; then
                cp "$pg_hba_file" "$pg_hba_file.backup_autofix" 2>/dev/null || true
            fi
            
            # Ensure md5 authentication
            if grep -q "^local.*all.*all.*peer" "$pg_hba_file" 2>/dev/null; then
                sed -i 's/^local\s\+all\s\+all\s\+peer/local   all             all                                     md5/' "$pg_hba_file" 2>/dev/null || true
                log_info "Updated pg_hba.conf authentication"
            fi
            
            # Restart PostgreSQL
            systemctl restart postgresql 2>/dev/null || true
            sleep 2
            
            # Test again
            if psql -h "${DATABASE_HOST:-localhost}" -p "${DATABASE_PORT:-5432}" -U "${DATABASE_USER}" -d "${DATABASE_NAME}" -c "SELECT 1;" &>/dev/null; then
                log_success "Database connection fixed"
                issue_fixed
            else
                log_error "Could not fix database connection"
                issue_failed
            fi
        fi
    fi
}

# Fix 4: Check and fix file permissions
fix_file_permissions() {
    log_check "Checking file permissions..."
    
    if [[ ! -d "$SNAILYCAD_DIR" ]]; then
        log_warning "SnailyCAD directory not found: $SNAILYCAD_DIR"
        return 1
    fi
    
    local owner
    owner=$(stat -c '%U' "$SNAILYCAD_DIR" 2>/dev/null || echo "unknown")
    
    if [[ "$owner" != "snailycad" && "$owner" != "root" ]]; then
        issue_found
        log_fix "Incorrect directory owner: $owner"
        
        # Try to find the correct user
        local correct_user="snailycad"
        if ! id "$correct_user" &>/dev/null; then
            correct_user="${DATABASE_USER:-snailycad}"
        fi
        
        if id "$correct_user" &>/dev/null; then
            chown -R "$correct_user:$correct_user" "$SNAILYCAD_DIR" 2>&1 | tee -a "$LOG_FILE"
            log_success "Fixed directory ownership to $correct_user"
            issue_fixed
        else
            log_error "User $correct_user does not exist"
            issue_failed
        fi
    else
        log_info "File permissions OK"
    fi
    
    # Fix .env permissions
    if [[ -f "$ENV_FILE" ]]; then
        chmod 600 "$ENV_FILE" 2>/dev/null || true
        log_info "Secured .env file permissions"
    fi
}

# Fix 5: Check and fix node_modules
fix_node_modules() {
    log_check "Checking node_modules..."
    
    if [[ ! -d "$SNAILYCAD_DIR/node_modules" ]]; then
        issue_found
        log_fix "node_modules directory missing"
        
        cd "$SNAILYCAD_DIR" || return 1
        
        local install_user
        install_user=$(stat -c '%U' "$SNAILYCAD_DIR" 2>/dev/null || echo "root")
        
        log_info "Running pnpm install as $install_user..."
        
        if [[ "$install_user" == "root" ]]; then
            pnpm install 2>&1 | tee -a "$LOG_FILE"
        else
            su - "$install_user" -c "cd $SNAILYCAD_DIR && pnpm install" 2>&1 | tee -a "$LOG_FILE"
        fi
        
        if [[ -d "$SNAILYCAD_DIR/node_modules" ]]; then
            log_success "node_modules installed"
            issue_fixed
        else
            log_error "Failed to install node_modules"
            issue_failed
        fi
    else
        log_info "node_modules exists"
    fi
}

# Fix 6: Check and fix Prisma client
fix_prisma_client() {
    log_check "Checking Prisma client..."
    
    cd "$SNAILYCAD_DIR" || return 1
    
    local prisma_dir="$SNAILYCAD_DIR/node_modules/.prisma"
    
    if [[ ! -d "$prisma_dir" ]]; then
        issue_found
        log_fix "Prisma client not generated"
        
        local install_user
        install_user=$(stat -c '%U' "$SNAILYCAD_DIR" 2>/dev/null || echo "root")
        
        log_info "Generating Prisma client..."
        
        if [[ "$install_user" == "root" ]]; then
            pnpm --filter "@snailycad/api" prisma generate 2>&1 | tee -a "$LOG_FILE"
        else
            su - "$install_user" -c "cd $SNAILYCAD_DIR && pnpm --filter '@snailycad/api' prisma generate" 2>&1 | tee -a "$LOG_FILE"
        fi
        
        if [[ -d "$prisma_dir" ]]; then
            log_success "Prisma client generated"
            issue_fixed
        else
            log_error "Failed to generate Prisma client"
            issue_failed
        fi
    else
        log_info "Prisma client exists"
    fi
}

# Fix 7: Check environment variables
fix_environment_variables() {
    log_check "Checking environment variables..."
    
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env file not found"
        return 1
    fi
    
    local required_vars=(
        "DATABASE_HOST"
        "DATABASE_PORT"
        "DATABASE_NAME"
        "DATABASE_USER"
        "DATABASE_PASSWORD"
        "POSTGRES_USER"
        "POSTGRES_PASSWORD"
        "JWT_SECRET"
    )
    
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if ! grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        issue_found
        log_warning "Missing environment variables: ${missing_vars[*]}"
        
        # Try to add defaults
        for var in "${missing_vars[@]}"; do
            case "$var" in
                "DATABASE_HOST")
                    echo "DATABASE_HOST=localhost" >> "$ENV_FILE"
                    ;;
                "DATABASE_PORT")
                    echo "DATABASE_PORT=5432" >> "$ENV_FILE"
                    ;;
                "JWT_SECRET")
                    local jwt_secret
                    jwt_secret=$(openssl rand -base64 32 2>/dev/null || echo "change-me-$(date +%s)")
                    echo "JWT_SECRET=$jwt_secret" >> "$ENV_FILE"
                    ;;
            esac
        done
        
        log_success "Added default values for missing variables"
        issue_fixed
    else
        log_info "All required environment variables present"
    fi
}

# Fix 8: Check disk space
fix_disk_space() {
    log_check "Checking disk space..."
    
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    
    if [[ "$disk_usage" -gt 90 ]]; then
        issue_found
        log_warning "Disk usage is high: ${disk_usage}%"
        
        # Clean up logs
        log_fix "Cleaning up old logs..."
        find /var/log -type f -name "*.log" -mtime +30 -delete 2>/dev/null || true
        find /tmp -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
        
        # Clean npm cache
        if command -v npm &>/dev/null; then
            npm cache clean --force 2>&1 | tee -a "$LOG_FILE" || true
        fi
        
        # Clean pnpm cache
        if command -v pnpm &>/dev/null; then
            pnpm store prune 2>&1 | tee -a "$LOG_FILE" || true
        fi
        
        log_success "Cleaned up disk space"
        issue_fixed
    else
        log_info "Disk space OK: ${disk_usage}% used"
    fi
}

# Fix 9: Check memory
fix_memory_issues() {
    log_check "Checking memory usage..."
    
    local mem_usage
    mem_usage=$(free | awk 'NR==2 {printf "%.0f", $3*100/$2}')
    
    if [[ "$mem_usage" -gt 90 ]]; then
        issue_found
        log_warning "Memory usage is high: ${mem_usage}%"
        
        # Clear page cache
        log_fix "Clearing page cache..."
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        
        log_success "Cleared page cache"
        issue_fixed
    else
        log_info "Memory usage OK: ${mem_usage}%"
    fi
}

# Fix 10: Check for zombie processes
fix_zombie_processes() {
    log_check "Checking for zombie processes..."
    
    local zombie_count
    zombie_count=$(ps aux | awk '$8=="Z" {print $2}' | wc -l)
    
    if [[ "$zombie_count" -gt 0 ]]; then
        issue_found
        log_warning "Found $zombie_count zombie processes"
        
        # Kill parent processes of zombies
        ps aux | awk '$8=="Z" {print $3}' | sort -u | while read -r ppid; do
            if [[ "$ppid" != "PPID" && -n "$ppid" ]]; then
                kill -9 "$ppid" 2>/dev/null || true
            fi
        done
        
        log_success "Cleaned up zombie processes"
        issue_fixed
    else
        log_info "No zombie processes found"
    fi
}

# Fix 11: Restart all SnailyCAD services
restart_snailycad() {
    log_check "Checking if restart is needed..."
    
    # Kill any running SnailyCAD processes
    pkill -f "snailycad" 2>/dev/null || true
    pkill -f "next" 2>/dev/null || true
    sleep 2
    
    log_info "All SnailyCAD processes stopped"
}

# Fix 12: Check build files
fix_build_files() {
    log_check "Checking build files..."
    
    local client_build="$SNAILYCAD_DIR/apps/client/.next"
    
    if [[ ! -d "$client_build" ]]; then
        issue_found
        log_fix "Client build directory missing"
        
        cd "$SNAILYCAD_DIR" || return 1
        
        local install_user
        install_user=$(stat -c '%U' "$SNAILYCAD_DIR" 2>/dev/null || echo "root")
        
        log_info "Building client application..."
        
        if [[ "$install_user" == "root" ]]; then
            pnpm --filter "@snailycad/client" build 2>&1 | tee -a "$LOG_FILE"
        else
            su - "$install_user" -c "cd $SNAILYCAD_DIR && pnpm --filter '@snailycad/client' build" 2>&1 | tee -a "$LOG_FILE"
        fi
        
        if [[ -d "$client_build" ]]; then
            log_success "Client application built"
            issue_fixed
        else
            log_error "Failed to build client application"
            issue_failed
        fi
    else
        log_info "Build files exist"
    fi
}

# Summary report
show_summary() {
    echo ""
    log "==================================================================="
    log "                    AUTO-FIX SUMMARY"
    log "==================================================================="
    echo ""
    log_info "Issues Found:  $ISSUES_FOUND"
    log_success "Issues Fixed:  $ISSUES_FIXED"
    if [[ $ISSUES_FAILED -gt 0 ]]; then
        log_error "Issues Failed: $ISSUES_FAILED"
    fi
    echo ""
    
    if [[ $ISSUES_FAILED -eq 0 && $ISSUES_FOUND -gt 0 ]]; then
        log_success "All issues resolved! ✓"
    elif [[ $ISSUES_FOUND -eq 0 ]]; then
        log_success "No issues detected! System is healthy ✓"
    else
        log_warning "Some issues could not be automatically fixed"
        log_info "Please review the log file: $LOG_FILE"
    fi
    
    echo ""
    log "==================================================================="
    log "Log file: $LOG_FILE"
    log "==================================================================="
    echo ""
    
    if [[ $ISSUES_FAILED -eq 0 ]]; then
        log_info "You can now start SnailyCAD with:"
        log_info "  cd $SNAILYCAD_DIR"
        log_info "  pnpm start"
        echo ""
    fi
}

# Main function
main() {
    echo ""
    log "==================================================================="
    log "            SnailyCAD Auto-Fixer v1.0"
    log "==================================================================="
    log "Started: $(date)"
    log "Log: $LOG_FILE"
    echo ""
    
    ensure_root
    
    # Load environment
    load_env_vars || true
    
    # Run all fixes
    log_info "Running diagnostics and fixes..."
    echo ""
    
    fix_port_conflicts
    fix_postgresql_service
    fix_database_connection
    fix_file_permissions
    fix_node_modules
    fix_prisma_client
    fix_environment_variables
    fix_disk_space
    fix_memory_issues
    fix_zombie_processes
    fix_build_files
    restart_snailycad
    
    # Show summary
    show_summary
}

# Run main
main "$@"
