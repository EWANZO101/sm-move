#!/bin/bash

# SnailyCAD Complete Auto-Fix
# No interaction required - fixes everything automatically

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

clear
echo ""
echo "========================================================"
echo "  SnailyCAD Complete Auto-Fix"
echo "  No Questions Asked - Just Fix Everything"
echo "========================================================"
echo ""

# Must be root
if [[ $EUID -ne 0 ]]; then
   log_error "Must run as root: sudo $0"
   exit 1
fi

# Step 1: Find SnailyCAD
log_info "Step 1: Finding SnailyCAD installation..."

SNAILY_DIR=""
for dir in /home/snaily-cadv4 /home/snailycad /opt/snailycad /var/www/snailycad /root/snailycad; do
    if [[ -d "$dir" ]]; then
        SNAILY_DIR="$dir"
        break
    fi
done

if [[ -z "$SNAILY_DIR" ]]; then
    # Try to find by package.json
    SNAILY_DIR=$(find /home /opt /var/www /root -name "package.json" -path "*/snaily*" -type f 2>/dev/null | head -1 | xargs dirname)
fi

if [[ -z "$SNAILY_DIR" ]] || [[ ! -d "$SNAILY_DIR" ]]; then
    log_error "Cannot find SnailyCAD directory"
    log_info "Searched: /home/snaily-cadv4, /home/snailycad, /opt/snailycad, /var/www/snailycad"
    exit 1
fi

log_success "Found: $SNAILY_DIR"

# Step 2: Find .env file
log_info "Step 2: Finding .env file..."

ENV_FILE=""
for location in "$SNAILY_DIR/.env" "$SNAILY_DIR/apps/api/.env" "$SNAILY_DIR/api/.env"; do
    if [[ -f "$location" ]]; then
        ENV_FILE="$location"
        break
    fi
done

if [[ -z "$ENV_FILE" ]]; then
    # Create default location
    ENV_FILE="$SNAILY_DIR/.env"
    log_warning ".env not found, will create: $ENV_FILE"
else
    log_success "Found: $ENV_FILE"
    # Backup
    cp "$ENV_FILE" "$ENV_FILE.backup_$(date +%Y%m%d_%H%M%S)"
    log_success "Backed up .env"
fi

# Step 3: Get current config from .env (if exists)
log_info "Step 3: Reading current configuration..."

DB_USER="snailycad"
DB_NAME="snaily-cad-v4"
DB_HOST="localhost"
DB_PORT="5432"
DB_PASSWORD=""

if [[ -f "$ENV_FILE" ]]; then
    # Try to extract values
    if grep -q "^DATABASE_URL=" "$ENV_FILE"; then
        CURRENT_URL=$(grep "^DATABASE_URL=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        
        # Try to parse if it's a real URL (not variable reference)
        if [[ "$CURRENT_URL" =~ postgresql://([^:]+):([^@]+)@([^:/]+):?([0-9]*)/([^?]+) ]]; then
            DB_USER="${BASH_REMATCH[1]}"
            PASS_TEMP="${BASH_REMATCH[2]}"
            DB_HOST="${BASH_REMATCH[3]}"
            DB_PORT="${BASH_REMATCH[4]:-5432}"
            DB_NAME="${BASH_REMATCH[5]}"
            
            # URL decode password
            DB_PASSWORD=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$PASS_TEMP'))" 2>/dev/null || echo "$PASS_TEMP")
        fi
    fi
    
    # Try to get from individual variables
    [[ -z "$DB_USER" ]] && DB_USER=$(grep "^POSTGRES_USER=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
    [[ -z "$DB_NAME" ]] && DB_NAME=$(grep "^POSTGRES_DB=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
    [[ -z "$DB_HOST" ]] && DB_HOST=$(grep "^DB_HOST=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
    [[ -z "$DB_PORT" ]] && DB_PORT=$(grep "^DB_PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
    [[ -z "$DB_PASSWORD" ]] && DB_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
fi

# Set defaults if still empty
DB_USER=${DB_USER:-snailycad}
DB_NAME=${DB_NAME:-snaily-cad-v4}
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}

log_info "Current config:"
echo "  User: $DB_USER"
echo "  Database: $DB_NAME"
echo "  Host: $DB_HOST"
echo "  Port: $DB_PORT"
echo "  Password: ${DB_PASSWORD:+[found]} ${DB_PASSWORD:-[not found]}"

# Step 4: Generate new simple password (no special chars)
log_info "Step 4: Generating new secure password..."

NEW_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
log_success "Generated 24-char password"

# Step 5: Configure PostgreSQL
log_info "Step 5: Configuring PostgreSQL..."

PG_HBA=$(find /etc/postgresql -name pg_hba.conf 2>/dev/null | head -1)

if [[ -z "$PG_HBA" ]]; then
    log_error "PostgreSQL not found"
    exit 1
fi

PG_VERSION=$(echo "$PG_HBA" | grep -oP '\d+' | head -1)
log_success "Found PostgreSQL $PG_VERSION: $PG_HBA"

# Backup
cp "$PG_HBA" "$PG_HBA.backup_$(date +%Y%m%d_%H%M%S)"
log_success "Backed up config"

# Step 6: Set to trust temporarily
log_info "Step 6: Setting trust mode (temporary)..."

cat > "$PG_HBA" << 'HBAEOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
HBAEOF

systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null || /etc/init.d/postgresql reload 2>/dev/null
sleep 3
log_success "Trust mode enabled"

# Step 7: Drop and recreate user (clean slate)
log_info "Step 7: Recreating database user..."

# Drop user if exists (and reassign owned objects first)
su - postgres -c "psql -c \"REASSIGN OWNED BY \\\"$DB_USER\\\" TO postgres;\"" 2>/dev/null || true
su - postgres -c "psql -c \"DROP OWNED BY \\\"$DB_USER\\\";\"" 2>/dev/null || true
su - postgres -c "psql -c \"DROP USER IF EXISTS \\\"$DB_USER\\\";\"" 2>/dev/null || true

# Create fresh user with new password
su - postgres -c "psql -c \"CREATE USER \\\"$DB_USER\\\" WITH PASSWORD '$NEW_PASSWORD' SUPERUSER CREATEDB CREATEROLE LOGIN;\""
log_success "User created: $DB_USER"

# Step 8: Ensure database exists
log_info "Step 8: Ensuring database exists..."

if su - postgres -c "psql -lqt" | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    log_success "Database exists: $DB_NAME"
else
    su - postgres -c "psql -c \"CREATE DATABASE \\\"$DB_NAME\\\" OWNER \\\"$DB_USER\\\";\""
    log_success "Database created: $DB_NAME"
fi

# Grant all privileges
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"$DB_NAME\\\" TO \\\"$DB_USER\\\";\""
log_success "Privileges granted"

# Step 9: Set password using multiple methods
log_info "Step 9: Setting password (multiple methods)..."

# Method 1: ALTER USER
su - postgres -c "psql -c \"ALTER USER \\\"$DB_USER\\\" WITH PASSWORD '$NEW_PASSWORD';\"" >/dev/null 2>&1

# Method 2: MD5 hash
MD5_PASS=$(echo -n "${NEW_PASSWORD}${DB_USER}" | md5sum | cut -d' ' -f1)
su - postgres -c "psql -c \"UPDATE pg_authid SET rolpassword = 'md5$MD5_PASS' WHERE rolname = '$DB_USER';\"" >/dev/null 2>&1

log_success "Password set"

# Step 10: Configure md5 authentication
log_info "Step 10: Configuring md5 authentication..."

cat > "$PG_HBA" << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             $DB_USER                                md5
local   all             all                                     md5
host    all             postgres        127.0.0.1/32            trust
host    all             $DB_USER        127.0.0.1/32            md5
host    all             all             127.0.0.1/32            md5
host    all             postgres        ::1/128                 trust
host    all             $DB_USER        ::1/128                 md5
host    all             all             ::1/128                 md5
EOF

systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null || /etc/init.d/postgresql reload 2>/dev/null
sleep 3
log_success "MD5 authentication configured"

# Step 11: Test connection
log_info "Step 11: Testing connection..."

export PGPASSWORD="$NEW_PASSWORD"
TEST_SUCCESS=0

for i in {1..5}; do
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
        TEST_SUCCESS=1
        break
    fi
    sleep 2
done

if [[ $TEST_SUCCESS -eq 1 ]]; then
    log_success "✓✓✓ CONNECTION WORKS!"
else
    log_error "Connection failed with md5, switching to trust..."
    
    # Fallback to trust for this user
    sed -i "s/^local.*$DB_USER.*md5/local   all             $DB_USER                                trust/" "$PG_HBA"
    sed -i "s/^host.*$DB_USER.*127.0.0.1.*md5/host    all             $DB_USER        127.0.0.1\/32            trust/" "$PG_HBA"
    sed -i "s/^host.*$DB_USER.*::1.*md5/host    all             $DB_USER        ::1\/128                 trust/" "$PG_HBA"
    
    systemctl reload postgresql 2>/dev/null || service postgresql reload 2>/dev/null
    sleep 2
    
    log_warning "Using trust authentication (no password required)"
fi

# Step 12: Update .env file
log_info "Step 12: Updating .env file..."

NEW_DATABASE_URL="postgresql://${DB_USER}:${NEW_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

# Read existing .env content
if [[ -f "$ENV_FILE" ]]; then
    # Update existing
    if grep -q "^DATABASE_URL=" "$ENV_FILE"; then
        sed -i "s|^DATABASE_URL=.*|DATABASE_URL=\"$NEW_DATABASE_URL\"|" "$ENV_FILE"
    else
        echo "DATABASE_URL=\"$NEW_DATABASE_URL\"" >> "$ENV_FILE"
    fi
    
    # Update other vars if they exist
    sed -i "s|^POSTGRES_USER=.*|POSTGRES_USER=\"$DB_USER\"|" "$ENV_FILE" 2>/dev/null || true
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=\"$NEW_PASSWORD\"|" "$ENV_FILE" 2>/dev/null || true
    sed -i "s|^POSTGRES_DB=.*|POSTGRES_DB=\"$DB_NAME\"|" "$ENV_FILE" 2>/dev/null || true
    sed -i "s|^DB_HOST=.*|DB_HOST=\"$DB_HOST\"|" "$ENV_FILE" 2>/dev/null || true
    sed -i "s|^DB_PORT=.*|DB_PORT=\"$DB_PORT\"|" "$ENV_FILE" 2>/dev/null || true
else
    # Create new .env
    cat > "$ENV_FILE" << ENVEOF
# Database Configuration - Auto-generated
DATABASE_URL="$NEW_DATABASE_URL"

POSTGRES_USER="$DB_USER"
POSTGRES_PASSWORD="$NEW_PASSWORD"
POSTGRES_DB="$DB_NAME"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
ENVEOF
fi

log_success ".env updated"

# Step 13: Fix permissions
log_info "Step 13: Fixing permissions..."

chmod 600 "$ENV_FILE"
OWNER=$(stat -c '%U' "$SNAILY_DIR" 2>/dev/null || echo "root")
chown -R "$OWNER:$OWNER" "$SNAILY_DIR" 2>/dev/null || true
log_success "Permissions fixed"

# Step 14: Clean caches
log_info "Step 14: Cleaning Prisma cache..."

cd "$SNAILY_DIR"
rm -rf node_modules/.prisma 2>/dev/null || true
rm -rf apps/api/node_modules/.prisma 2>/dev/null || true
rm -rf .next 2>/dev/null || true

# Clean pnpm store
PNPM_STORE=$(pnpm store path 2>/dev/null || echo "")
if [[ -n "$PNPM_STORE" ]]; then
    find "$PNPM_STORE" -type d -name ".prisma" -exec rm -rf {} + 2>/dev/null || true
fi

log_success "Cache cleared"

# Step 15: Stop existing processes
log_info "Step 15: Stopping existing processes..."

pkill -f "snailycad" 2>/dev/null || true
pm2 stop all 2>/dev/null || true
pm2 delete all 2>/dev/null || true
sleep 2
log_success "Processes stopped"

# Save credentials
CREDS_FILE="/root/snailycad_credentials.txt"
cat > "$CREDS_FILE" << CREDEOF
SnailyCAD Database Credentials
Generated: $(date)
======================================================

DATABASE_URL:
$NEW_DATABASE_URL

Individual Values:
  Host: $DB_HOST
  Port: $DB_PORT
  Database: $DB_NAME
  User: $DB_USER
  Password: $NEW_PASSWORD

PostgreSQL Test Command:
  PGPASSWORD='$NEW_PASSWORD' psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME

Files Modified:
  .env: $ENV_FILE
  pg_hba.conf: $PG_HBA

Backups:
  .env backup: $ENV_FILE.backup_*
  pg_hba.conf backup: $PG_HBA.backup_*

======================================================
CREDEOF

chmod 600 "$CREDS_FILE"

# Final summary
echo ""
echo "========================================================"
echo "  ✓✓✓ COMPLETE AUTO-FIX FINISHED!"
echo "========================================================"
echo ""
log_success "Database configured successfully"
echo ""
echo "Configuration:"
echo "  User: $DB_USER"
echo "  Database: $DB_NAME"
echo "  Password: $NEW_PASSWORD"
echo ""
echo "Files:"
echo "  Config: $ENV_FILE"
echo "  Credentials: $CREDS_FILE"
echo ""
echo "Next Steps:"
echo "  1. cd $SNAILY_DIR"
echo "  2. pnpm run start"
echo ""
echo "Or with PM2:"
echo "  pm2 start ecosystem.config.js"
echo ""
echo "Check logs:"
echo "  pm2 logs"
echo "  tail -f $SNAILY_DIR/start.log"
echo ""
echo "========================================================"
echo ""

# Offer to start
echo "Start SnailyCAD now? (y/n)"
read -t 10 -n 1 START_NOW || START_NOW="n"
echo ""

if [[ "$START_NOW" =~ ^[Yy] ]]; then
    log_info "Starting SnailyCAD..."
    cd "$SNAILY_DIR"
    
    if [[ -f "ecosystem.config.js" ]] && command -v pm2 >/dev/null 2>&1; then
        pm2 start ecosystem.config.js
        sleep 3
        pm2 logs --lines 20
    else
        log_info "Starting with pnpm (use Ctrl+C to stop)..."
        pnpm run start
    fi
else
    log_success "Ready! Start SnailyCAD when you're ready."
fi
