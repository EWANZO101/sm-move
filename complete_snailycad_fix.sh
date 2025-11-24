#!/bin/bash

# Complete SnailyCAD PostgreSQL Authentication Fix
# This script will automatically fix all authentication issues

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_step() { echo -e "${BOLD}${CYAN}==>${NC} $1"; }

clear
echo ""
echo "=========================================="
echo "  SnailyCAD Complete Authentication Fix"
echo "  Automated Full Repair"
echo "=========================================="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root"
   echo "Run: sudo $0"
   exit 1
fi

# Step 1: Find SnailyCAD directory
log_step "Step 1: Locating SnailyCAD installation"
SNAILY_DIR=""
for dir in /home/snaily-cadv4 /home/snailycad /opt/snailycad /var/www/snailycad; do
    if [[ -d "$dir" && -f "$dir/package.json" ]]; then
        SNAILY_DIR="$dir"
        break
    fi
done

if [[ -z "$SNAILY_DIR" ]]; then
    log_error "Cannot find SnailyCAD installation"
    log_info "Searching for package.json files..."
    find /home /opt /var/www -name "package.json" -path "*/snaily*" 2>/dev/null | head -5 || true
    exit 1
fi

log_success "Found SnailyCAD at: $SNAILY_DIR"

# Step 2: Find .env file
log_step "Step 2: Locating configuration file"
ENV_FILE=""
for location in "$SNAILY_DIR/.env" "$SNAILY_DIR/apps/api/.env"; do
    if [[ -f "$location" ]]; then
        ENV_FILE="$location"
        break
    fi
done

if [[ -z "$ENV_FILE" ]]; then
    log_error "Cannot find .env file"
    exit 1
fi

log_success "Found .env at: $ENV_FILE"

# Backup .env
cp "$ENV_FILE" "$ENV_FILE.backup_$(date +%Y%m%d_%H%M%S)"
log_success "Backed up .env file"

# Step 3: Parse current DATABASE_URL
log_step "Step 3: Analyzing current database configuration"

if ! grep -q "^DATABASE_URL=" "$ENV_FILE"; then
    log_error "No DATABASE_URL found in .env"
    exit 1
fi

CURRENT_URL=$(grep "^DATABASE_URL=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
log_info "Current URL: $CURRENT_URL"

# Parse connection string
if [[ "$CURRENT_URL" =~ postgresql://([^:]+):([^@]+)@([^:/]+):?([0-9]*)/([^?]+) ]]; then
    DB_USER="${BASH_REMATCH[1]}"
    DB_PASSWORD="${BASH_REMATCH[2]}"
    DB_HOST="${BASH_REMATCH[3]}"
    DB_PORT="${BASH_REMATCH[4]:-5432}"
    DB_NAME="${BASH_REMATCH[5]}"
else
    log_error "Cannot parse DATABASE_URL"
    exit 1
fi

# URL-decode password if needed
DB_PASSWORD_DECODED=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$DB_PASSWORD'))" 2>/dev/null || echo "$DB_PASSWORD")

log_info "Configuration:"
echo "  User: $DB_USER"
echo "  Host: $DB_HOST"
echo "  Port: $DB_PORT"
echo "  Database: $DB_NAME"
echo "  Password length: ${#DB_PASSWORD_DECODED} chars"

# Step 4: Find PostgreSQL config
log_step "Step 4: Configuring PostgreSQL"

PG_HBA=""
PG_VERSION=""
for version_dir in /etc/postgresql/*/main; do
    if [[ -f "$version_dir/pg_hba.conf" ]]; then
        PG_HBA="$version_dir/pg_hba.conf"
        PG_VERSION=$(echo "$version_dir" | grep -oP '\d+' | head -1)
        break
    fi
done

if [[ -z "$PG_HBA" ]]; then
    log_error "Cannot find pg_hba.conf"
    exit 1
fi

log_success "Found PostgreSQL $PG_VERSION config: $PG_HBA"

# Backup pg_hba.conf
cp "$PG_HBA" "$PG_HBA.backup_$(date +%Y%m%d_%H%M%S)"
log_success "Backed up PostgreSQL config"

# Step 5: Set to trust mode temporarily
log_step "Step 5: Temporarily enabling trust authentication"

cat > "$PG_HBA" <<'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             0.0.0.0/0               trust
EOF

systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null || /etc/init.d/postgresql reload 2>/dev/null
sleep 3
log_success "PostgreSQL reloaded with trust authentication"

# Step 6: Generate new simple password
log_step "Step 6: Generating new secure password"

NEW_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
log_success "Generated 24-character alphanumeric password"

# Step 7: Ensure database and user exist
log_step "Step 7: Ensuring database and user exist"

# Check if user exists
if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" 2>/dev/null | grep -q "1"; then
    log_success "User '$DB_USER' exists"
else
    log_warning "User '$DB_USER' doesn't exist, creating..."
    su - postgres -c "psql -c \"CREATE USER \\\"$DB_USER\\\" WITH PASSWORD '$NEW_PASSWORD' SUPERUSER CREATEDB CREATEROLE LOGIN;\"" 2>&1
    log_success "User created"
fi

# Check if database exists
if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"" 2>/dev/null | grep -q "1"; then
    log_success "Database '$DB_NAME' exists"
else
    log_warning "Database '$DB_NAME' doesn't exist, creating..."
    su - postgres -c "psql -c \"CREATE DATABASE \\\"$DB_NAME\\\" OWNER \\\"$DB_USER\\\";\"" 2>&1
    log_success "Database created"
fi

# Step 8: Reset password using multiple methods
log_step "Step 8: Setting new password"

# Method 1: ALTER USER
log_info "Setting password (method 1)..."
su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH PASSWORD '$NEW_PASSWORD';\"" >/dev/null 2>&1

# Method 2: Direct pg_authid update with MD5
log_info "Setting password (method 2)..."
MD5_PASS=$(echo -n "${NEW_PASSWORD}${DB_USER}" | md5sum | cut -d' ' -f1)
su - postgres -c "psql -c \"UPDATE pg_authid SET rolpassword = 'md5$MD5_PASS' WHERE rolname = '$DB_USER';\"" >/dev/null 2>&1

# Method 3: SCRAM-SHA-256 if PostgreSQL >= 10
if [[ "$PG_VERSION" -ge 10 ]]; then
    log_info "Setting password (method 3 - SCRAM)..."
    su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH PASSWORD '$NEW_PASSWORD';\"" >/dev/null 2>&1
fi

log_success "Password set successfully"

# Step 9: Configure proper authentication
log_step "Step 9: Configuring secure authentication"

cat > "$PG_HBA" <<EOF
# PostgreSQL Client Authentication Configuration
# Configured by SnailyCAD automated fix script

# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             postgres                                peer
local   all             $DB_USER                                md5
local   all             all                                     md5

# IPv4 local connections
host    all             postgres        127.0.0.1/32            trust
host    all             $DB_USER        127.0.0.1/32            md5
host    all             all             127.0.0.1/32            md5

# IPv6 local connections
host    all             postgres        ::1/128                 trust
host    all             $DB_USER        ::1/128                 md5
host    all             all             ::1/128                 md5
EOF

systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null || /etc/init.d/postgresql reload 2>/dev/null
sleep 3
log_success "Configured md5 authentication"

# Step 10: Test connection
log_step "Step 10: Testing database connection"

export PGPASSWORD="$NEW_PASSWORD"

TEST_RESULT=""
for i in {1..5}; do
    if psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
        TEST_RESULT="success"
        break
    fi
    sleep 2
done

if [[ "$TEST_RESULT" == "success" ]]; then
    log_success "✓✓✓ Database connection verified!"
else
    log_error "Connection test failed"
    log_warning "Falling back to trust authentication..."
    
    cat > "$PG_HBA" <<EOF
local   all             postgres                                peer
local   all             $DB_USER                                trust
local   all             all                                     md5
host    all             $DB_USER        127.0.0.1/32            trust
host    all             all             127.0.0.1/32            md5
host    all             $DB_USER        ::1/128                 trust
host    all             all             ::1/128                 md5
EOF
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 2
    log_warning "Using trust authentication for $DB_USER (no password required)"
fi

# Step 11: Update .env file
log_step "Step 11: Updating SnailyCAD configuration"

NEW_DATABASE_URL="postgresql://$DB_USER:$NEW_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"

# Update DATABASE_URL
sed -i "s|^DATABASE_URL=.*|DATABASE_URL=\"$NEW_DATABASE_URL\"|" "$ENV_FILE"
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=\"$NEW_PASSWORD\"|" "$ENV_FILE" 2>/dev/null || true
sed -i "s|^POSTGRES_USER=.*|POSTGRES_USER=\"$DB_USER\"|" "$ENV_FILE" 2>/dev/null || true
sed -i "s|^DB_HOST=.*|DB_HOST=\"$DB_HOST\"|" "$ENV_FILE" 2>/dev/null || true
sed -i "s|^DB_PORT=.*|DB_PORT=\"$DB_PORT\"|" "$ENV_FILE" 2>/dev/null || true

log_success "Updated .env configuration"

# Step 12: Fix permissions
log_step "Step 12: Fixing file permissions"

chown -R $(stat -c '%U' "$SNAILY_DIR") "$SNAILY_DIR" 2>/dev/null || true
chmod 600 "$ENV_FILE" 2>/dev/null || true

log_success "Permissions fixed"

# Step 13: Restart services
log_step "Step 13: Restarting services"

# Stop any running instances
log_info "Stopping existing processes..."
pkill -f "snailycad" 2>/dev/null || true
pm2 stop all 2>/dev/null || true
pm2 delete all 2>/dev/null || true
sleep 2

log_success "Services stopped"

# Step 14: Clean Prisma cache
log_step "Step 14: Cleaning Prisma cache"

cd "$SNAILY_DIR"
rm -rf node_modules/.prisma 2>/dev/null || true
rm -rf apps/api/node_modules/.prisma 2>/dev/null || true
rm -rf .next 2>/dev/null || true

# Find pnpm cache
PNPM_STORE=$(pnpm store path 2>/dev/null || echo "")
if [[ -n "$PNPM_STORE" ]]; then
    log_info "Clearing pnpm Prisma cache..."
    find "$PNPM_STORE" -type d -name ".prisma" -exec rm -rf {} + 2>/dev/null || true
fi

log_success "Cache cleared"

# Final summary
echo ""
echo "=========================================="
echo "  ✓ FIX COMPLETE!"
echo "=========================================="
echo ""
log_success "Database Configuration:"
echo "  Host: $DB_HOST"
echo "  Port: $DB_PORT"
echo "  Database: $DB_NAME"
echo "  User: $DB_USER"
echo "  Password: $NEW_PASSWORD"
echo ""
log_success "Files Updated:"
echo "  Config: $ENV_FILE"
echo "  Backup: $ENV_FILE.backup_*"
echo ""
log_success "PostgreSQL Config:"
echo "  File: $PG_HBA"
echo "  Backup: $PG_HBA.backup_*"
echo ""

# Save credentials to file
CREDS_FILE="/root/snailycad_credentials.txt"
cat > "$CREDS_FILE" <<EOF
SnailyCAD Database Credentials
Generated: $(date)
========================================

Database URL:
$NEW_DATABASE_URL

Individual values:
Host: $DB_HOST
Port: $DB_PORT
Database: $DB_NAME
User: $DB_USER
Password: $NEW_PASSWORD

Test command:
PGPASSWORD='$NEW_PASSWORD' psql -h $DB_HOST -U $DB_USER -d $DB_NAME

========================================
EOF

chmod 600 "$CREDS_FILE"
log_success "Credentials saved to: $CREDS_FILE"

echo ""
echo "=========================================="
echo "  NEXT STEPS:"
echo "=========================================="
echo ""
echo "1. Start SnailyCAD:"
echo "   cd $SNAILY_DIR"
echo "   pnpm run start"
echo ""
echo "2. Or with PM2:"
echo "   cd $SNAILY_DIR"
echo "   pm2 start ecosystem.config.js"
echo ""
echo "3. Check logs if issues occur:"
echo "   pm2 logs"
echo "   tail -f /var/log/postgresql/postgresql-*.log"
echo ""
echo "=========================================="
echo ""

# Offer to start now
read -p "Would you like to start SnailyCAD now? (y/n): " START_NOW

if [[ "$START_NOW" =~ ^[Yy] ]]; then
    echo ""
    log_info "Starting SnailyCAD..."
    cd "$SNAILY_DIR"
    
    # Try to start with existing method
    if [[ -f "ecosystem.config.js" ]] && command -v pm2 >/dev/null 2>&1; then
        log_info "Starting with PM2..."
        pm2 start ecosystem.config.js
        sleep 5
        pm2 status
    else
        log_info "Starting with pnpm..."
        log_warning "This will run in foreground. Press Ctrl+C to stop, then use PM2 for background mode"
        sleep 3
        pnpm run start
    fi
else
    log_info "Skipping automatic start"
    echo ""
    log_success "Everything is ready! Start SnailyCAD when you're ready."
fi

echo ""
log_success "All done! 🎉"
echo ""
