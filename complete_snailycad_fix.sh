#!/bin/bash

# PostgreSQL Reinstall and Configuration Script
# This script removes PostgreSQL, reinstalls it, and configures it using .env file

set -e  # Exit on any error

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
    print_error ".env file not found in common locations"
    print_error "Searched: /home/, /home/snaily-cadv4/, /home/snailycad/, /home/snaily_backup/"
    echo ""
    print_message "Please specify the .env file location:"
    read -p "Enter full path to .env file: " ENV_FILE
    if [ ! -f "$ENV_FILE" ]; then
        print_error "File not found at: $ENV_FILE"
        exit 1
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

# Step 4.5: Check for and extract backup file
print_message "Step 4.5: Checking for backup files in /home/snaily-cadv4/..."

# Find the most recent snaily_backup tar.gz file
BACKUP_FILE=$(ls -t /home/snaily-cadv4/snaily_backup_*.tar.gz 2>/dev/null | head -1)

if [ -n "$BACKUP_FILE" ]; then
    print_message "Found backup file: $BACKUP_FILE"
    
    # Create temporary extraction directory
    EXTRACT_DIR="/tmp/snaily_restore_$$"
    mkdir -p "$EXTRACT_DIR"
    
    print_message "Extracting backup file..."
    tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR"
    
    if [ $? -eq 0 ]; then
        print_message "Backup extracted successfully to $EXTRACT_DIR"
        
        # Look for SQL dump file in extracted contents
        SQL_DUMP=$(find "$EXTRACT_DIR" -name "*.sql" -type f | head -1)
        
        if [ -n "$SQL_DUMP" ]; then
            print_message "Found SQL dump: $SQL_DUMP"
            IMPORT_SQL="yes"
        else
            print_warning "No SQL dump found in backup file"
            IMPORT_SQL="no"
        fi
        
        # Check if there's a .env file in the backup
        BACKUP_ENV=$(find "$EXTRACT_DIR" -name ".env" -type f | head -1)
        if [ -n "$BACKUP_ENV" ] && [ -z "$ENV_FILE" ]; then
            print_message "Found .env in backup, using it"
            ENV_FILE="$BACKUP_ENV"
            # Re-export variables from backup .env
            export $(grep -v '^#' "$ENV_FILE" | xargs)
            DB_HOST="${POSTGRES_HOST:-localhost}"
            DB_PORT="${POSTGRES_PORT:-5432}"
            DB_NAME="${POSTGRES_DB:-snailycad}"
            DB_USER="${POSTGRES_USER:-postgres}"
            DB_PASSWORD="${POSTGRES_PASSWORD}"
        fi
    else
        print_error "Failed to extract backup file"
        IMPORT_SQL="no"
    fi
else
    print_warning "No backup file found in /home/snaily-cadv4/"
    print_message "Continuing without backup import..."
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
    print_message "This may take several minutes depending on database size..."
    
    # Set password for psql connection
    export PGPASSWORD="$DB_PASSWORD"
    
    # Import the SQL dump
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" < "$SQL_DUMP" 2>/dev/null; then
        print_message "Database imported successfully from backup!"
    else
        print_warning "Database import encountered some issues, but may have partially succeeded"
        print_message "You may need to review the database manually"
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
    print_message "Step 9: Skipping database import (no backup file found)"
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
