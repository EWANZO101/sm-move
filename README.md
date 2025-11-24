Here’s a clean, organized **README.md** built from the commands you provided:

---

# SnailyCAD Backup & Import Scripts

This guide walks you through downloading, giving execution permissions, and running the backup and import scripts for SnailyCAD.

---

## 📦 Backup Script (Primary Method)

### 1. Download the backup script

```bash
wget -O /home/backup_snaily.sh https://raw.githubusercontent.com/EWANZO101/sm-move/main/backup_snaily.sh
```

### 2. Make it executable

```bash
chmod +x /home/backup_snaily.sh
```

### 3. Run the script

```bash
/home/backup_snaily.sh
```
##########################################################
sudo systemctl stop start-snaily-cadv4.service


pm2 stop all

#################################################################
---

## 📥 Import Script (Primary Method)

### 1. Download the import script

```bash
wget -O /home/import_snaily.sh https://raw.githubusercontent.com/EWANZO101/sm-move/main/import_snaily.sh
```

### 2. Make it executable

```bash
chmod +x /home/import_snaily.sh
```

### 3. Run the script

```bash
/home/import_snaily.sh
```

---

# Download the script using wget
wget https://raw.githubusercontent.com/EWANZO101/sm-move/main/complete_snailycad_fix.sh

# Make it executable
chmod +x complete_snailycad_fix.sh

# Run it with sudo
sudo bash complete_snailycad_fix.sh

If you want, I can also format this with headings, badges, or add instructions for scheduling backups with cron.
