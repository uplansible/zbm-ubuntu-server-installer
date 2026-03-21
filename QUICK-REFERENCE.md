# Quick Reference - ZFS & Sanoid Commands

## Snapshot Operations

### View Snapshots
```bash
# All snapshots
zfs list -t snapshot

# Snapshots for specific dataset
zfs list -t snapshot -r rpool/ROOT/ubuntu-1

# With size information
zfs list -t snapshot -o name,used,referenced,creation

# Human-readable sizes
zfs list -t snapshot -o name,used -S creation
```

### Create Manual Snapshots
```bash
# Quick snapshot with timestamp
sudo zfs snapshot rpool/ROOT/ubuntu-1@manual-$(date +%Y%m%d-%H%M)

# Before system changes
sudo zfs snapshot rpool/ROOT/ubuntu-1@before-major-change

# Datapool snapshot
sudo zfs snapshot datapool/docker@backup-$(date +%Y%m%d)
```

### Delete Snapshots
```bash
# Single snapshot
sudo zfs destroy rpool/ROOT/ubuntu-1@old-snapshot

# Range of snapshots
sudo zfs destroy rpool/ROOT/ubuntu-1@snap1%snap2

# All snapshots in a dataset (DANGEROUS!)
sudo zfs destroy -r rpool/ROOT/ubuntu-1@%
```

### Rollback
```bash
# Rollback to specific snapshot (destroys newer snapshots!)
sudo zfs rollback rpool/ROOT/ubuntu-1@working-state

# Rollback and reboot
sudo zfs rollback rpool/ROOT/ubuntu-1@working-state && sudo reboot
```

## Sanoid Operations

### Manual Snapshot Management
```bash
# Take snapshots now (uses config rules)
sudo sanoid --take-snapshots --verbose

# Prune old snapshots now
sudo sanoid --prune-snapshots --verbose

# Dry run (see what would happen)
sudo sanoid --prune-snapshots --verbose --dry-run

# Both take and prune
sudo sanoid --cron
```

### View Sanoid Configuration
```bash
# Show config
cat /etc/sanoid/sanoid.conf

# Edit config
sudo nano /etc/sanoid/sanoid.conf

# Check timer status
systemctl status sanoid.timer

# View recent runs
journalctl -u sanoid.service -n 50
```

### Example Sanoid Config

#### For rpool (already configured)
```ini
[rpool/ROOT/ubuntu-1]
    use_template = template_production
    recursive = yes
```

#### For datapool (add after creating datapool)
```ini
[datapool/docker]
    use_template = template_production
    recursive = yes

[datapool/services]
    use_template = template_production
    recursive = no

[template_production]
    frequently = 0      # Every 15 min (0 = disabled)
    hourly = 36         # Keep 36 hours (1.5 days)
    daily = 30          # Keep 30 days
    monthly = 6         # Keep 6 months
    yearly = 0          # Keep X years (0 = disabled)
    autosnap = yes      # Take automatic snapshots
    autoprune = yes     # Delete old snapshots
```

#### Custom template for frequently-changing data
```ini
[datapool/logs]
    use_template = frequent_data

[template_frequent_data]
    frequently = 4      # Keep 4 (last hour)
    hourly = 24         # Keep 24 hours
    daily = 7           # Keep 7 days
    monthly = 0         # Don't keep monthly
    yearly = 0
    autosnap = yes
    autoprune = yes
```

## Syncoid Backup Operations

### One-time Backup
```bash
# To remote server (initial full backup)
sudo syncoid rpool/ROOT/ubuntu-1 user@backup-server:backup/myserver

# To local pool
sudo syncoid rpool/ROOT/ubuntu-1 backup/myserver-rpool

# To USB drive (assuming mounted as /mnt/backup)
sudo syncoid rpool/ROOT/ubuntu-1 /mnt/backup/myserver-rpool
```

### Incremental Backups
```bash
# Regular incremental (after initial full backup)
sudo syncoid --no-sync-snap rpool/ROOT/ubuntu-1 user@backup-server:backup/myserver

# With compression (slower, less bandwidth)
sudo syncoid --compress=lz4 rpool/ROOT/ubuntu-1 user@backup-server:backup/myserver

# Resume interrupted transfer
sudo syncoid --no-sync-snap rpool/ROOT/ubuntu-1 user@backup-server:backup/myserver
```

### Backup Multiple Datasets
```bash
# Recursive backup (includes all child datasets)
sudo syncoid -r rpool/ROOT user@backup-server:backup/rpool

# Backup both rpool and datapool
sudo syncoid rpool/ROOT/ubuntu-1 user@backup-server:backup/myserver-rpool
sudo syncoid -r datapool user@backup-server:backup/myserver-datapool
```

### Automated Backups with Cron
```bash
# Edit root's crontab
sudo crontab -e

# Add daily backup at 2 AM
0 2 * * * /usr/sbin/syncoid --no-sync-snap rpool/ROOT/ubuntu-1 user@backup-server:backup/myserver

# Add hourly datapool backup
0 * * * * /usr/sbin/syncoid -r datapool user@backup-server:backup/myserver-datapool
```

## ZFS Pool Management

### Pool Status
```bash
# Quick status
sudo zpool status

# Detailed status
sudo zpool status -v

# Show all properties
sudo zpool get all rpool
```

### Pool Maintenance
```bash
# Scrub pool (checks data integrity)
sudo zpool scrub rpool

# Check scrub progress
sudo zpool status

# Stop scrub
sudo zpool scrub -s rpool

# Clear errors after fixing
sudo zpool clear rpool
```

### Pool Properties
```bash
# View all properties
sudo zpool get all rpool

# Set autotrim (for SSDs)
sudo zpool set autotrim=on rpool

# Enable/disable auto-snapshot
sudo zfs set com.sun:auto-snapshot=true rpool/ROOT/ubuntu-1
```

## ZFS Dataset Management

### View Datasets
```bash
# List all datasets
zfs list

# With more details
zfs list -o name,used,avail,refer,mountpoint

# Show space usage
zfs list -o name,used,usedsnap,usedds,usedchild

# Recursive list
zfs list -r rpool
```

### Dataset Properties
```bash
# View all properties
zfs get all rpool/ROOT/ubuntu-1

# View specific property
zfs get compression rpool/ROOT/ubuntu-1

# Set compression
sudo zfs set compression=zstd datapool/docker

# Set quota
sudo zfs set quota=100G datapool/docker

# Set reservation
sudo zfs set reservation=50G datapool/database
```

### Create New Datasets
```bash
# Simple dataset
sudo zfs create datapool/newdata

# With properties
sudo zfs create -o compression=zstd -o quota=500G datapool/media

# Encrypted dataset
sudo zfs create -o encryption=on -o keyformat=passphrase datapool/sensitive

# Dataset with mount point
sudo zfs create -o mountpoint=/srv/docker datapool/docker
```

## System Updates

### Before Major Updates
```bash
# Create pre-update snapshot
sudo zfs snapshot rpool/ROOT/ubuntu-1@before-update-$(date +%Y%m%d)

# Do update
sudo apt update && sudo apt upgrade

# If something breaks, rollback
sudo zfs rollback rpool/ROOT/ubuntu-1@before-update-$(date +%Y%m%d)
sudo reboot
```

### Update ZFSBootMenu
```bash
# After kernel updates
sudo update-zbm

# Verify it worked
ls -la /boot/efi/EFI/ZBM/
```

## ZFSBootMenu Usage

### At Boot
- **Enter ZFSBootMenu**: Default boot loader
- **Select BE**: Arrow keys + Enter
- **View Snapshots**: `Ctrl+S`
- **Clone & Promote**: `Ctrl+X` (recommended for rollback)
- **Create Duplicate BE**: `Enter` on snapshot
- **Recovery Shell**: `Ctrl+R`
- **Kernel Command Line**: `Ctrl+L`
- **Refresh**: `Ctrl+W` (re-import read-write)

### In Recovery Shell
```bash
# Import pool
zpool import -f rpool

# Check status
zpool status

# Mount datasets
zfs mount rpool/ROOT/ubuntu-1

# Exit to menu
exit
```

## Monitoring

### Disk Space
```bash
# Pool usage
zfs list -o name,used,avail,refer

# Snapshot space usage
zfs list -t snapshot -o name,used -s used

# Find what's using space
ncdu /
```

### Performance
```bash
# I/O statistics
zpool iostat -v 2

# ARC statistics
arc_summary

# Detailed pool I/O
zpool iostat -v 1
```

### Health Checks
```bash
# Pool health
sudo zpool status -x

# SMART status
sudo smartctl -a /dev/nvme0n1

# Check for errors
dmesg | grep -i zfs
journalctl -u zfs-import-cache.service
```

## Common Issues & Fixes

### Out of Space
```bash
# Find large snapshots
zfs list -t snapshot -o name,used -s used | head -20

# Delete old snapshots
sudo zfs destroy rpool/ROOT/ubuntu-1@old-snapshot

# Adjust Sanoid retention
sudo nano /etc/sanoid/sanoid.conf
sudo sanoid --prune-snapshots --verbose
```

### Pool Import Fails
```bash
# Force import
sudo zpool import -f rpool

# Import from alternate location
sudo zpool import -d /dev/disk/by-id rpool

# Clear errors
sudo zpool clear rpool
```

### Dataset Won't Mount
```bash
# Check if already mounted
zfs get mounted rpool/ROOT/ubuntu-1

# Unmount and remount
sudo zfs unmount rpool/ROOT/ubuntu-1
sudo zfs mount rpool/ROOT/ubuntu-1

# Check mount point
zfs get mountpoint rpool/ROOT/ubuntu-1
```

## Useful Aliases

Add to `~/.bashrc`:
```bash
# ZFS aliases
alias zl='zfs list -o name,used,avail,refer,mountpoint'
alias zls='zfs list -t snapshot -o name,used,referenced,creation'
alias zp='zpool status'
alias zpi='zpool iostat -v 2'

# Snapshot shortcuts
alias zsn='sudo zfs snapshot rpool/ROOT/ubuntu-1@manual-$(date +%Y%m%d-%H%M)'
alias zslast='zfs list -t snapshot -s creation | tail -5'

# Sanoid
alias ssnap='sudo sanoid --take-snapshots --verbose'
alias sprune='sudo sanoid --prune-snapshots --verbose'
```

## Emergency Recovery

### Boot from Live USB and import pool
```bash
# From Ubuntu Live USB
sudo apt update && sudo apt install zfsutils-linux

# Import and mount
sudo zpool import -f -R /mnt rpool
sudo zfs mount rpool/ROOT/ubuntu-1

# Chroot to fix issues
sudo mount --rbind /dev /mnt/dev
sudo mount --rbind /proc /mnt/proc
sudo mount --rbind /sys /mnt/sys
sudo chroot /mnt

# Fix and exit
exit
sudo umount -R /mnt
sudo zpool export rpool
reboot
```
