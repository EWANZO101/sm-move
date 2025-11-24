#!/bin/bash

# PostgreSQL Reinstall and Configuration Script
# This script removes PostgreSQL, reinstalls it, and configures it using .env file

# Note: Not using 'set -e' to allow graceful error handling

echo "=== PostgreSQL Reinstall and Configuration Script ==="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

# Step 1: Remove PostgreSQL (with self-healing)
print_message "Step 1: Checking and removing existing PostgreSQL installation..."

# Check if PostgreSQL is installed
if systemctl list-units --full -all | grep -q postgresql.service; then
    print_message "PostgreSQL service found, stopping..."
    systemctl stop postgresql 2>/dev/null || true
else
    print_warning "PostgreSQL service not found, skipping stop"
fi

# Check if PostgreSQL packages are installed
if dpkg -l | grep -q postgresql; then
    print_message "PostgreSQL packages found, removing..."
    apt-get --purge remove -y postgresql postgresql-* 2>/dev/null || true
    apt-get autoremove -y
    apt-get autoclean
    print_message "PostgreSQL packages removed successfully"
else
    print_warning "PostgreSQL packages not installed, skipping removal"
fi

# Clean up directories if they exist
if [ -d "/var/lib/postgresql/" ]; then
    rm -rf /var/lib/postgresql/
    print_message "Removed /var/lib/postgresql/"
fi
if [ -d "/var/log/postgresql/" ]; then
    rm -rf /var/log/postgresql/
    print_message "Removed /var/log/postgresql/"
fi
if [ -d "/etc/postgresql/" ]; then
    rm -rf /etc/postgresql/
    print_message "Removed /etc/postgresql/"
fi

print_message "PostgreSQL cleanup completed"
echo ""

# Step 2: Reinstall PostgreSQL
print_message "Step 2: Installing PostgreSQL..."
apt-get update
apt-get install -y postgresql postgresql-contrib
print_message "PostgreSQL installed successfully"
echo ""

# Step 3: Start PostgreSQL service
print_message "Step 3: Starting PostgreSQL service..."
systemctl start postgresql
systemctl enable postgresql
sleep 3
print_message "PostgreSQL service started"
echo ""

# Step 4: Load .env file
print_message "Step 4: Checking for .env file..."

# Check multiple locations for .env file
if [ -f "/home/.env" ]; then
    print_warning ".env file already exists in /home, using existing file"
    ENV_FILE="/home/.env"
elif [ -f "/home/snaily-cadv4/.env" ]; then
    print_message "Found .env in /home/snaily-cadv4/, using existing file"
    ENV_FILE="/home/snaily-cadv4/.env"
elif [ -f "/home/snailycad/.env" ]; then
    print_message "Found .env in /home/snailycad/, using existing file"
    ENV_FILE="/home/snailycad/.env"
elif [ -f "/home/snaily_backup/.env" ]; then
    print_message "Importing .env from /home/snaily_backup/.env..."
    ENV_FILE="/home/snaily_backup/.env"
else
    # No .env found, search for backup tar.gz files
    print_warning ".env file not found in standard locations"
    print_message "Searching for backup files..."
    
    # Search for backup files in multiple locations, sorted by date (most recent first)
    BACKUP_FILE=$(find /home -maxdepth 1 -name "snaily_backup_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    
    if [ -z "$BACKUP_FILE" ]; then
        BACKUP_FILE=$(find /home/snaily-cadv4 -maxdepth 1 -name "snaily_backup_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    fi
    
    if [ -z "$BACKUP_FILE" ]; then
        BACKUP_FILE=$(find /home/snailycad -maxdepth 1 -name "snaily_backup_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    fi
    
    if [ -n "$BACKUP_FILE" ]; then
        print_message "Found backup file: $(basename $BACKUP_FILE)"
        print_message "Location: $BACKUP_FILE"
        print_message "Extracting .env from backup..."
        
        # Create temporary extraction directory
        EXTRACT_DIR="/tmp/snaily_restore_$$"
        mkdir -p "$EXTRACT_DIR"
        
        # Extract the backup
        tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
        
        # Look for .env file in extracted contents (can be named .env or env_backup_*)
        BACKUP_ENV=$(find "$EXTRACT_DIR" -name ".env" -type f | head -1)
        
        if [ -z "$BACKUP_ENV" ]; then
            # Look for env_backup_* files
            BACKUP_ENV=$(find "$EXTRACT_DIR" -name "env_backup_*" -type f | head -1)
        fi
        
        if [ -n "$BACKUP_ENV" ]; then
            print_message "Found env file in backup: $(basename $BACKUP_ENV)"
            print_message "Copying to /home/.env"
            cp "$BACKUP_ENV" /home/.env
            ENV_FILE="/home/.env"
            print_message ".env file extracted successfully from backup"
        else
            print_error ".env file not found in backup"
            print_message "Backup contents:"
            tar -tzf "$BACKUP_FILE"
            rm -rf "$EXTRACT_DIR"
            exit 1
        fi
    else
        print_error ".env file not found and no backup files found"
        print_error "Searched locations:"
        echo "  - /home/.env"
        echo "  - /home/snaily-cadv4/.env"
        echo "  - /home/snailycad/.env"
        echo "  - /home/snaily_backup/.env"
        echo "  - /home/snaily_backup_*.tar.gz"
        echo "  - /home/snaily-cadv4/snaily_backup_*.tar.gz"
        echo "  - /home/snailycad/snaily_backup_*.tar.gz"
        echo ""
        print_message "Please specify the .env file location:"
        read -p "Enter full path to .env file: " ENV_FILE
        if [ ! -f "$ENV_FILE" ]; then
            print_error "File not found at: $ENV_FILE"
            exit 1
        fi
    fi
fi

print_message "Loading configuration from $ENV_FILE..."

# Source the .env file and extract database credentials
export $(grep -v '^#' "$ENV_FILE" | xargs)

# Extract database configuration
DB_HOST="${POSTGRES_HOST:-localhost}"
DB_PORT="${POSTGRES_PORT:-5432}"
DB_NAME="${POSTGRES_DB:-snailycad}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PASSWORD="${POSTGRES_PASSWORD}"

if [ -z "$DB_PASSWORD" ]; then
    print_error "POSTGRES_PASSWORD not found in .env file"
    exit 1
fi

print_message "Database Configuration:"
echo "  Host: $DB_HOST"
echo "  Port: $DB_PORT"
echo "  Database: $DB_NAME"
echo "  User: $DB_USER"
echo ""

# Step 4.5: Check for and extract backup file for SQL import
print_message "Step 4.5: Checking for backup SQL dump..."

# If we already extracted a backup above, use that
if [ -z "$EXTRACT_DIR" ] || [ ! -d "$EXTRACT_DIR" ]; then
    # Find the most recent snaily_backup tar.gz file, sorted by modification time
    print_message "Searching for backup files..."
    
    BACKUP_FILE=$(find /home -maxdepth 1 -name "snaily_backup_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    
    if [ -z "$BACKUP_FILE" ]; then
        BACKUP_FILE=$(find /home/snaily-cadv4 -maxdepth 1 -name "snaily_backup_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    fi
    
    if [ -z "$BACKUP_FILE" ]; then
        BACKUP_FILE=$(find /home/snailycad -maxdepth 1 -name "snaily_backup_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    fi
    
    if [ -n "$BACKUP_FILE" ]; then
        print_message "Found backup file: $(basename $BACKUP_FILE)"
        print_message "Location: $BACKUP_FILE"
        
        # Create temporary extraction directory
        EXTRACT_DIR="/tmp/snaily_restore_$$"
        mkdir -p "$EXTRACT_DIR"
        
        print_message "Extracting backup file..."
        tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR" 2>/dev/null
    fi
fi

# Look for SQL dump in extracted backup
if [ -d "$EXTRACT_DIR" ]; then
    # Look for db_backup_*.sql files first (most specific)
    SQL_DUMP=$(find "$EXTRACT_DIR" -name "db_backup_*.sql" -type f | head -1)
    
    # If not found, look for any .sql file
    if [ -z "$SQL_DUMP" ]; then
        SQL_DUMP=$(find "$EXTRACT_DIR" -name "*.sql" -type f | head -1)
    fi
    
    if [ -n "$SQL_DUMP" ]; then
        print_message "Found SQL dump: $(basename $SQL_DUMP)"
        IMPORT_SQL="yes"
    else
        print_warning "No SQL dump found in backup file"
        print_message "Extracted backup contents:"
        ls -lah "$EXTRACT_DIR"
        IMPORT_SQL="no"
    fi
else
    print_warning "No backup file found for SQL import"
    IMPORT_SQL="no"
fi
echo ""

# Step 5: Create database user (with self-healing)
print_message "Step 5: Configuring database user '$DB_USER'..."

# Check if user exists
USER_EXISTS=$(sudo -u postgres psql -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")

if [ "$USER_EXISTS" = "1" ]; then
    print_warning "User '$DB_USER' already exists, updating password..."
    sudo -u postgres psql -d postgres -c "ALTER USER \"$DB_USER\" WITH PASSWORD '$DB_PASSWORD';"
    print_message "User '$DB_USER' password updated"
else
    print_message "Creating new user '$DB_USER'..."
    sudo -u postgres psql -d postgres -c "CREATE USER \"$DB_USER\" WITH PASSWORD '$DB_PASSWORD';"
    print_message "User '$DB_USER' created successfully"
fi
echo ""

# Step 6: Grant superuser privileges
print_message "Step 6: Granting SUPERUSER privileges to '$DB_USER'..."
sudo -u postgres psql -d postgres -c "ALTER USER \"$DB_USER\" WITH SUPERUSER;"
print_message "SUPERUSER privileges granted"
echo ""

# Step 7: Create database (with self-healing)
print_message "Step 7: Configuring database '$DB_NAME'..."

# Check if database exists
DB_EXISTS=$(sudo -u postgres psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")

if [ "$DB_EXISTS" = "1" ]; then
    print_warning "Database '$DB_NAME' already exists, skipping creation"
    print_message "Updating database owner to '$DB_USER'..."
    sudo -u postgres psql -d postgres -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\";" 2>/dev/null || true
else
    print_message "Creating new database '$DB_NAME'..."
    sudo -u postgres psql -d postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"
    print_message "Database '$DB_NAME' created successfully"
fi
echo ""

# Step 8: Grant all privileges
print_message "Step 8: Granting privileges..."
sudo -u postgres psql -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";"
print_message "Privileges granted"
echo ""

# Step 9: Import database from backup if available
if [ "$IMPORT_SQL" = "yes" ] && [ -n "$SQL_DUMP" ]; then
    print_message "Step 9: Importing database from backup..."
    print_message "SQL file: $(basename $SQL_DUMP)"
    print_message "This may take several minutes depending on database size..."
    echo ""
    
    # Set password for psql connection
    export PGPASSWORD="$DB_PASSWORD"
    
    # Import the SQL dump with verbose output
    print_message "Starting import..."
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SQL_DUMP" 2>&1 | tee /tmp/psql_import.log; then
        print_message "Database imported successfully from backup!"
    else
        EXIT_CODE=$?
        print_warning "Database import encountered issues (exit code: $EXIT_CODE)"
        print_message "Checking if data was imported..."
        
        # Check if any tables were created
        TABLE_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo "0")
        
        if [ "$TABLE_COUNT" -gt 0 ]; then
            print_message "Found $TABLE_COUNT tables - import appears partially successful"
            print_warning "Check the import log at /tmp/psql_import.log for details"
        else
            print_error "No tables found - import may have failed"
            print_message "Import log saved to: /tmp/psql_import.log"
        fi
    fi
    
    # Cleanup
    unset PGPASSWORD
    
    # Remove temporary extraction directory
    if [ -d "$EXTRACT_DIR" ]; then
        print_message "Cleaning up temporary files..."
        rm -rf "$EXTRACT_DIR"
    fi
    echo ""
else
    print_message "Step 9: Skipping database import (no backup SQL file found)"
    echo ""
fi

# Verify installation
print_message "Verifying PostgreSQL setup..."
sudo -u postgres psql -d postgres -c "\du" | grep "$DB_USER" && print_message "User verified" || print_error "User verification failed"
sudo -u postgres psql -d postgres -c "\l" | grep "$DB_NAME" && print_message "Database verified" || print_error "Database verification failed"
echo ""

print_message "=== PostgreSQL Reinstall and Configuration Complete ==="
if [ "$IMPORT_SQL" = "yes" ]; then
    print_message "Database has been restored from backup: $(basename $BACKUP_FILE)"
fi
print_message "You can now connect using:"
echo "  psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
echo ""
if [ "$IMPORT_SQL" != "yes" ]; then
    print_message "To import a database dump manually, use:"
    echo "  psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME < your_dump.sql"
fi
