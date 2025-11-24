#!/bin/bash

# Emergency PostgreSQL Password Fixer for SnailyCAD
# Run this if authentication is failing
# 
# Usage:
#   Interactive: sudo ./emergency_password_fix.sh
#   Automated:   sudo ./emergency_password_fix.sh --auto <user> <database> <password>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

echo ""
echo "================================================"
echo "  SnailyCAD Emergency Password Fixer"
echo "================================================"
echo ""

# Check for automated mode
if [[ "$1" == "--auto" ]] && [[ -n "$2" ]] && [[ -n "$3" ]] && [[ -n "$4" ]]; then
    # Automated mode with arguments
    DB_USER="$2"
    DB_NAME="$3"
    DB_PASSWORD="$4"
    log_info "Running in automated mode"
else
    # Interactive mode - get credentials
    read -p "Database user [snailycad]: " DB_USER
    DB_USER=${DB_USER:-snailycad}

    read -p "Database name [snailycad]: " DB_NAME
    DB_NAME=${DB_NAME:-snailycad}

    read -sp "Database password: " DB_PASSWORD
    echo ""
fi

if [[ -z "$DB_PASSWORD" ]]; then
    log_error "Password cannot be empty"
    exit 1
fi

log_info "User: $DB_USER"
log_info "Database: $DB_NAME"
log_info "Password: [${#DB_PASSWORD} characters]"
echo ""

# Find pg_hba.conf
PG_HBA=""
for version_dir in /etc/postgresql/*/main; do
    if [[ -f "$version_dir/pg_hba.conf" ]]; then
        PG_HBA="$version_dir/pg_hba.conf"
        break
    fi
done

if [[ -z "$PG_HBA" ]]; then
    log_error "PostgreSQL config not found"
    exit 1
fi

log_info "Found: $PG_HBA"

# Backup
cp "$PG_HBA" "$PG_HBA.backup_emergency" 2>/dev/null || true
log_success "Backed up config"

# Set to trust temporarily
log_info "Setting authentication to TRUST (temporary)..."
cat > "$PG_HBA" <<EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOF

# Reload PostgreSQL
systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
sleep 2
log_success "PostgreSQL reloaded"

# Reset password using multiple methods
log_info "Resetting password..."

# Method 1: Direct ALTER
log_info "Method 1: ALTER USER..."
su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH PASSWORD '$DB_PASSWORD';\"" 2>&1

# Method 2: MD5 hash
log_info "Method 2: MD5 hash..."
MD5_PASS=$(echo -n "${DB_PASSWORD}${DB_USER}" | md5sum | cut -d' ' -f1)
su - postgres -c "psql -c \"UPDATE pg_authid SET rolpassword = 'md5$MD5_PASS' WHERE rolname = '$DB_USER';\"" 2>&1

# Verify user exists
if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" 2>/dev/null | grep -q "1"; then
    log_success "User exists in database"
else
    log_warning "User doesn't exist, creating..."
    su - postgres -c "psql -c \"CREATE USER \\\"$DB_USER\\\" WITH PASSWORD '$DB_PASSWORD' SUPERUSER CREATEDB CREATEROLE LOGIN;\"" 2>&1
fi

# Now switch to md5 authentication
log_info "Switching to md5 authentication..."
cat > "$PG_HBA" <<EOF
# Emergency fix by SnailyCAD password fixer
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
log_success "Switched to md5"

# Test connection
log_info "Testing connection..."
export PGPASSWORD="$DB_PASSWORD"

if psql -h 127.0.0.1 -U "$DB_USER" -d postgres -c "SELECT 'OK';" 2>&1 | grep -q "OK"; then
    log_success "✓✓✓ CONNECTION WORKS! ✓✓✓"
    echo ""
    log_success "Password fixed successfully!"
    echo ""
    log_info "Test command:"
    echo "  PGPASSWORD='$DB_PASSWORD' psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME"
    echo ""
else
    log_error "Connection still failing"
    log_warning "Falling back to TRUST authentication for this user..."
    
    # Use trust as last resort
    sed -i "s/^local.*all.*$DB_USER.*md5/local   all             $DB_USER                                trust/" "$PG_HBA" 2>/dev/null
    sed -i "s/^host.*all.*$DB_USER.*127.0.0.1.*md5/host    all             $DB_USER        127.0.0.1\/32            trust/" "$PG_HBA" 2>/dev/null
    sed -i "s/^host.*all.*$DB_USER.*::1.*md5/host    all             $DB_USER        ::1\/128                 trust/" "$PG_HBA" 2>/dev/null
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 2
    
    if psql -h 127.0.0.1 -U "$DB_USER" -d postgres -c "SELECT 'OK';" 2>&1 | grep -q "OK"; then
        log_success "Connection works with TRUST authentication"
        log_warning "WARNING: No password required for $DB_USER"
        log_warning "This is less secure but will allow SnailyCAD to work"
    else
        log_error "All methods failed"
        log_info "Restoring original config..."
        cp "$PG_HBA.backup_emergency" "$PG_HBA" 2>/dev/null || true
        systemctl reload postgresql 2>/dev/null || true
    fi
fi

echo ""
echo "================================================"
echo "Log: Check /var/log/postgresql/ for details"
echo "Config: $PG_HBA"
echo "Backup: $PG_HBA.backup_emergency"
echo "================================================"
echo ""
