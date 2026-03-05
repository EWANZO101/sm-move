# SnailyCAD Backup, Import & Repair Scripts

This guide explains how to download, prepare, and run the SnailyCAD
backup, import, and repair scripts.

These scripts help you: - Backup your SnailyCAD installation - Import /
restore backups - Fix common SnailyCAD issues

------------------------------------------------------------------------

## 📦 Backup Script

Use this script to create a backup of your SnailyCAD installation.

### 1. Download the Script

``` bash
wget -O /home/backup_snaily.sh https://raw.githubusercontent.com/EWANZO101/sm-move/main/backup_snaily.sh
```

### 2. Make the Script Executable

``` bash
chmod +x /home/backup_snaily.sh
```

### 3. Stop SnailyCAD Services (Recommended)

``` bash
sudo systemctl stop start-snaily-cadv4.service
pm2 stop all
```

### 4. Run the Backup Script

``` bash
/home/backup_snaily.sh
```

------------------------------------------------------------------------

## 📥 Import Script

Use this script to restore or import a SnailyCAD backup.

### 1. Download the Script

``` bash
wget -O /home/import_snaily.sh https://raw.githubusercontent.com/EWANZO101/sm-move/main/import_snaily.sh
```

### 2. Make the Script Executable

``` bash
chmod +x /home/import_snaily.sh
```

### 3. Run the Import Script

``` bash
/home/import_snaily.sh
```

------------------------------------------------------------------------

## 🛠 Complete SnailyCAD Repair Script

This script attempts to automatically fix common SnailyCAD issues.

### 1. Download the Script

``` bash
wget https://raw.githubusercontent.com/EWANZO101/sm-move/main/complete_snailycad_fix.sh
```

### 2. Make it Executable

``` bash
chmod +x complete_snailycad_fix.sh
```

### 3. Run the Script

``` bash
sudo bash complete_snailycad_fix.sh
```

------------------------------------------------------------------------

## 🔄 Restart SnailyCAD Services

After completing a backup, import, or repair, restart services:

``` bash
sudo systemctl start start-snaily-cadv4.service
pm2 start all
```

------------------------------------------------------------------------

## ⚠️ Important Notes

-   Always backup your system before performing imports or fixes.
-   Stopping services before backup helps prevent database corruption.
-   These scripts assume SnailyCAD v4 systemd + PM2 setup.

------------------------------------------------------------------------

## 📁 Repository

https://github.com/EWANZO101/sm-move
