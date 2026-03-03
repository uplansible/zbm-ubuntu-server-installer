# Ubuntu 24.04 ZFSBootMenu Simple Installation Guide

## Overview

> **Disclaimer:** This script is provided "as is", without warranty of any kind. Use at your own risk. The author accepts no responsibility for data loss or system damage. **Back up all important data before running.**

This script creates a **monolithic** ZFS root pool installation - perfect for treating the entire root filesystem (including /home) as a single entity that can be easily snapshotted and rolled back.

**✨ Version 3.0.4 - Documentation & License**
- ✅ Works on both NVMe and SATA/SAS disks
- ✅ Comprehensive input validation with decimal size support
- ✅ Robust error handling and automatic cleanup
- ✅ Verification at every critical step
- ✅ Network configuration included
- ✅ Fixed critical bugs from v2.0 (heredoc expansion, Sanoid templates)
- ✅ Encrypted swap (ephemeral random key, no plaintext swap on disk)
- ✅ Persistent install log copied into installed system
- ✅ /tmp as tmpfs (RAM-backed, not snapshotted)

### Architecture

**Disk Layout (NVMe example):**
```
/dev/nvme0n1p1  1GB    EFI System Partition
/dev/nvme0n1p2  8GB    Swap
/dev/nvme0n1p3  80GB   rpool (ZFS root)
/dev/nvme0n1p4  ~1.9TB datapool (for manual creation later)
```

**Disk Layout (SATA example):**
```
/dev/sda1       1GB    EFI System Partition
/dev/sda2       8GB    Swap
/dev/sda3       80GB   rpool (ZFS root)
/dev/sda4       ~1.9TB datapool (for manual creation later)
```

*Script automatically detects disk type and uses correct partition naming.*

**ZFS Structure:**
```
rpool/ROOT/ubuntu-1    <- Everything (root + home) in ONE dataset
```

**Benefits of monolithic structure:**
- Single snapshot = entire system state
- Simple rollback (no dataset dependencies)
- Easy backup with syncoid
- Treat as atomic unit

## Prerequisites

1. **Ubuntu 24.04 Live USB** - Boot from this
2. **Internet connection** - Required for package downloads
3. **Backup** - All data on target disk will be destroyed!

## Installation Steps

### Part 1: Initial Installation (from Live USB)

1. **Boot Ubuntu 24.04 Live USB**

2. **Open terminal** (Ctrl+Alt+T)

3. **Download the script:**
   ```bash
   wget https://raw.githubusercontent.com/uplansible/zbm-ubuntu-server-installer/main/zbm-ubuntu-server-installer.sh
   # OR copy from USB drive
   chmod +x zbm-ubuntu-server-installer.sh
   ```

4. **Edit configuration variables:**
   ```bash
   nano zbm-ubuntu-server-installer.sh
   ```

   Change these at the top of the script:
   ```bash
   DISK="/dev/nvme0n1"          # Your disk (NVMe: /dev/nvme0n1, SATA: /dev/sda)
   HOSTNAME="myserver"           # Your hostname (lowercase, alphanumeric, dashes)
   USERNAME="admin"              # Your username (lowercase, alphanumeric, underscores, dashes)
   TIMEZONE="Europe/Zurich"      # Your timezone (must exist in /usr/share/zoneinfo)
   LOCALE="en_US.UTF-8"          # Your locale (format: language_COUNTRY.encoding)
   ```

   **⚠️ Input Validation:** The script will automatically validate these values:
   - `HOSTNAME`: 1-63 characters, lowercase letters/numbers/dashes only
   - `USERNAME`: Must start with lowercase letter or underscore
   - `TIMEZONE`: Must be a valid timezone file (e.g., `America/New_York`, `Europe/London`)
   - `LOCALE`: Must match format `xx_XX.UTF-8`
   - `DISK`: Must exist and be large enough (automatically checked)

   To find your disk device:
   ```bash
   lsblk -d -o NAME,SIZE,TYPE
   ```

5. **Run initial installation:**
   ```bash
   sudo ./zbm-ubuntu-server-installer.sh initial
   ```

   **What happens:**
   - Validates your configuration (disk, hostname, username, timezone, locale)
   - Checks disk size is sufficient
   - Type `YES` to confirm (disk will be wiped!)
   - Partitions disk and creates ZFS pool
   - Installs Ubuntu base system
   - Configures network (DHCP on all Ethernet interfaces)
   - Installs ZFSBootMenu
   - Verifies installation completed successfully
   - Wait 15-30 minutes (depending on internet speed)

   **✅ Built-in verification checks:**
   - ZFSBootMenu EFI file exists
   - Boot properties configured correctly
   - Network configuration created
   - EFI boot entry added

   **🔧 Automatic cleanup:** If installation fails, the script automatically cleans up mounts and exports pools

   **⚠️ Default passwords:** Note the temporary passwords shown at the end:
   - Root: `root`
   - User: same as USERNAME
   - **CHANGE THESE IMMEDIATELY AFTER FIRST BOOT!**

6. **Reboot:**
   - Remove USB drive
   - System will boot into ZFSBootMenu
   - Select the boot environment and press Enter

### Part 2: Post-Reboot Setup

1. **Login** with the temporary credentials shown during installation

2. **Run post-reboot setup:**
   ```bash
   sudo /root/zbm-ubuntu-server-installer.sh postreboot
   ```

3. **Verify network connectivity:**
   ```bash
   ip addr show        # Check IP address assigned
   ping -c 3 8.8.8.8   # Test internet connectivity
   ```

   Network is configured for DHCP by default. If you need static IP, edit `/etc/netplan/01-netcfg.yaml`

4. **Change passwords immediately:**
   ```bash
   passwd              # Change your user password
   sudo passwd root    # Change root password
   ```

5. **Create datapool (when ready):**

   First, identify your datapool partition:
   ```bash
   lsblk
   ```

   Look for partition 4 (the largest one). Then create the pool:
   ```bash
   # For NVMe disks:
   # First, change partition type to ZFS (BF00)
   sudo sgdisk -t4:BF00 /dev/nvme0n1

   # Then create the pool
   sudo zpool create -o ashift=12 \
                     -O compression=lz4 \
                     -O atime=off \
                     -O relatime=on \
                     datapool /dev/nvme0n1p4

   # For SATA disks:
   # First, change partition type to ZFS (BF00)
   sudo sgdisk -t4:BF00 /dev/sda

   # Then create the pool
   sudo zpool create -o ashift=12 \
                     -O compression=lz4 \
                     -O atime=off \
                     -O relatime=on \
                     datapool /dev/sda4
   
   # Create datasets
   sudo zfs create datapool/docker
   sudo zfs create datapool/services
   ```

6. **Configure Sanoid for datapool:**
   ```bash
   sudo nano /etc/sanoid/sanoid.conf
   ```

   Add:
   ```ini
   [datapool/docker]
       use_template = template_production
       recursive = yes
   ```

## What's New in Version 3.0

### Bug Fixes (from v2.0)
- **Fixed Heredoc Variable Expansion**: Variables now correctly expand in chroot scripts
  - Locale, timezone, username, and disk variables now work properly
- **Fixed Sanoid Template**: Snapshots now created automatically (template name mismatch fixed)
- **Improved Error Handling**: Datapool cleanup added to both error handlers
- **Better Partition Extraction**: More robust efibootmgr partition number detection

### Enhanced Validation
- **Decimal Size Support**: Now accepts sizes like 1.5G or 512M
  - Supports both M (megabytes) and G (gigabytes) suffixes
- **Pre-flight Checks**: Validates disk exists before size check
- **Partition Verification**: Confirms all partitions created successfully
- **Mounted Disk Check**: Prevents accidental data loss
- **Debootstrap Verification**: Confirms base system installation completed
- **ZFS Module Check**: Verifies ZFS is available before starting

### Security Improvements
- **HTTPS APT Sources**: All package downloads now use HTTPS
- **Better Error Context**: Each chroot operation has explicit error checking

### Installation Reliability
- **Step-by-Step Verification**: Checks after each critical operation
- **Improved Error Messages**: More helpful guidance when things go wrong
- **Automatic Cleanup**: Both installation phases clean up on failure

## Daily Usage

### Snapshot Management

**View snapshots:**
```bash
zfs list -t snapshot
```

**Manual snapshot:**
```bash
sudo zfs snapshot rpool/ROOT/ubuntu-1@manual-backup
```

**Automatic snapshots:**
- Sanoid creates snapshots hourly/daily/monthly
- APT hook creates snapshot before each `apt upgrade`

### Rollback System

**From running system (minor issues):**
```bash
sudo zfs rollback rpool/ROOT/ubuntu-1@autosnap_2024-12-01_12:00:00
sudo reboot
```

**From ZFSBootMenu (major issues/won't boot):**
1. Reboot and enter ZFSBootMenu
2. Press `Ctrl+S` to view snapshots
3. Select the snapshot you want to restore
4. Press `Ctrl+X` for "clone and promote" (recommended)
5. Boot into restored system

### Backup with Syncoid

**To another server:**
```bash
# One-time full backup
sudo syncoid rpool/ROOT/ubuntu-1 backup-server:backup/myserver-rpool

# Incremental backups (run regularly)
sudo syncoid --no-sync-snap rpool/ROOT/ubuntu-1 backup-server:backup/myserver-rpool
```

**To external USB drive:**
```bash
# Create pool on USB
sudo zpool create backup /dev/sdX

# Backup
sudo syncoid rpool/ROOT/ubuntu-1 backup/myserver-rpool
```

## Maintenance

### Update ZFSBootMenu

After kernel updates:
```bash
sudo update-zbm
```

### Check pool health
```bash
sudo zpool status
sudo zpool list
```

### Scrub pools (monthly recommended)
```bash
sudo zpool scrub rpool
sudo zpool scrub datapool  # once created
```

### Prune old snapshots manually
```bash
# Sanoid does this automatically, but if needed:
sudo sanoid --prune-snapshots --verbose
```

## Troubleshooting

### Validation Errors During Installation

**"Invalid USERNAME" error:**
```
Error: Invalid USERNAME 'Admin'. Must start with lowercase letter...
```
- Username must be lowercase only
- Can contain letters, numbers, underscores, dashes
- Must start with a letter or underscore
- Examples: `admin`, `john_doe`, `user123`

**"Invalid HOSTNAME" error:**
```
Error: Invalid HOSTNAME 'My-Server'. Must be 1-63 characters...
```
- Hostname must be lowercase only
- Can contain letters, numbers, and dashes
- Must start and end with alphanumeric
- Examples: `myserver`, `web-01`, `db-primary`

**"Invalid TIMEZONE" error:**
```
Error: Invalid TIMEZONE 'US/Pacific'.
```
- Check available timezones: `ls /usr/share/zoneinfo/`
- Use format: `Continent/City`
- Examples: `America/New_York`, `Europe/London`, `Asia/Tokyo`

**"Disk is too small" error:**
```
Error: Disk is too small!
       Disk size: 50GB
       Required: 91GB minimum
```
- Check your partition size settings in the script
- Reduce `RPOOL_SIZE` if disk is smaller
- Or use a larger disk

**"Network not configured" warning:**
- This is usually safe to ignore
- Network will be configured via DHCP on first boot
- Check with `ip addr show` after booting

### System won't boot

1. Enter ZFSBootMenu
2. Press `Ctrl+R` for recovery shell
3. Check pool status: `zpool status rpool`
4. Import pool: `zpool import -f rpool`
5. Check datasets: `zfs list`

### Ran out of space in rpool

Check snapshot usage:
```bash
zfs list -t snapshot -o name,used,referenced
```

Delete old snapshots:
```bash
sudo zfs destroy rpool/ROOT/ubuntu-1@old-snapshot
```

### Resize rpool (if needed)

Not recommended, but if you must:
```bash
# This is complex - consider backing up and reinstalling instead
# You'd need to resize the partition, then zpool online -e
```

## Important Notes

1. **Monolithic Design Philosophy:**
   - rpool = OS state (treat as immutable)
   - datapool = your data (can change freely)
   - Never put important data in /root or /home (it's in rpool!)

2. **Before Major Updates:**
   ```bash
   sudo zfs snapshot rpool/ROOT/ubuntu-1@before-upgrade-$(date +%Y%m%d)
   ```

3. **Test Rollbacks:**
   Practice rolling back in ZFSBootMenu so you know the process

4. **Regular Backups:**
   Set up a cron job for syncoid to backup rpool regularly

5. **Encryption:**
   - This setup has NO encryption on rpool
   - Add encryption to datapool datasets if needed:
     ```bash
     sudo zfs create -o encryption=on -o keyformat=passphrase datapool/encrypted
     ```

## Resources

- **ZFSBootMenu:** https://github.com/zbm-dev/zfsbootmenu
- **Sanoid:** https://github.com/jimsalterjrs/sanoid
- **OpenZFS Docs:** https://openzfs.github.io/openzfs-docs/
- **Ubuntu ZFS Guide:** https://ubuntu.com/tutorials/setup-zfs-storage-pool

## Support

The script includes verbose output. If something fails:
1. Note the error message
2. Check logs: `dmesg`, `journalctl -xe`
3. Verify disk device name is correct
4. Check internet connectivity during installation
