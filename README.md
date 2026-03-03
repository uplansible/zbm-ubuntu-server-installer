# Ubuntu 24.04 ZFSBootMenu Server Installation

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange.svg)](https://ubuntu.com)
[![ZFS](https://img.shields.io/badge/ZFS-OpenZFS-blue.svg)](https://openzfs.org)

Automated installation script for Ubuntu 24.04 Server with ZFS root filesystem and ZFSBootMenu bootloader. Features a monolithic ZFS architecture optimized for easy snapshots and system rollbacks.

> **Disclaimer:** This script is provided "as is", without warranty of any kind, express or implied. Use at your own risk. The author accepts no responsibility for data loss, system damage, or any other issues arising from use of this script. **Always back up your data before proceeding.**

## ✨ Features
- 🗂️ **Monolithic ZFS Root** - Single dataset for entire system (easy to snapshot/rollback)
- 📸 **Automatic Snapshots** - Sanoid manages hourly, daily, and monthly snapshots
- 🔄 **Easy Rollback** - ZFSBootMenu allows booting from any snapshot
- 🔧 **APT Integration** - Automatic snapshot before every `apt upgrade`
- 💾 **Backup Ready** - Simple replication with Syncoid to remote servers or USB drives
- 🚀 **Boot from Snapshots** - No GRUB, direct EFI boot with ZFSBootMenu

## 📋 Quick Start

### Requirements
- Ubuntu 24.04 Live USB
- Target disk with at least 90GB (default: 80GB rpool + 8GB swap + 1GB EFI + buffer)
- Internet connection
- UEFI boot mode (required for ZFSBootMenu)

### Installation (5 minutes + download time)

1. **Boot Ubuntu 24.04 Live USB**

2. **Download the script:**
   ```bash
   wget https://raw.githubusercontent.com/uplansible/zbm-ubuntu-server-installer/main/zbm-ubuntu-server-installer.sh
   chmod +x zbm-ubuntu-server-installer.sh
   ```

3. **Edit configuration:**
   ```bash
   nano zbm-ubuntu-server-installer.sh
   ```

   Configure at top of file:
   ```bash
   DISK="/dev/sda"              # Your disk (NVMe: nvme0n1, SATA: sda)
   HOSTNAME="myserver"          # Lowercase, alphanumeric, dashes
   USERNAME="admin"             # Lowercase, alphanumeric, underscores
   TIMEZONE="Europe/Zurich"     # Valid timezone
   LOCALE="en_US.UTF-8"         # Locale format
   ```

4. **Run installation:**
   ```bash
   sudo ./zbm-ubuntu-server-installer.sh initial
   ```

   Type `YES` to confirm. Wait 15-30 minutes.

5. **Reboot and complete setup:**
   ```bash
   # After first boot, login and run:
   sudo /root/zbm-ubuntu-server-installer.sh postreboot

   # CHANGE DEFAULT PASSWORDS IMMEDIATELY:
   passwd
   sudo passwd root
   ```

## 📖 Documentation

- **[INSTALLATION-GUIDE.md](INSTALLATION-GUIDE.md)** - Complete step-by-step installation guide
- **[QUICK-REFERENCE.md](QUICK-REFERENCE.md)** - Common ZFS/Sanoid/Syncoid commands
- **[CHANGELOG.md](CHANGELOG.md)** - Detailed version history and changelog
- **[TEST-VALIDATION.md](TEST-VALIDATION.md)** - Testing checklist and validation procedures
- **[CLAUDE.md](CLAUDE.md)** - Developer guidance for working with this codebase

## 🏗️ Architecture

### Disk Layout

**Partition Structure:**
```
Partition 1:  1GB    EFI System Partition
Partition 2:  8GB    Swap
Partition 3:  80GB   rpool (ZFS root)
Partition 4:  Rest   datapool (manual creation)
```

**ZFS Structure:**
```
rpool/ROOT/ubuntu-1    ← Monolithic dataset (root + /home)
datapool/              ← Optional: for user data (you create later)
  ├── docker
  ├── services
  └── ...
```

### Design Philosophy

- **rpool = System State** - Treat as immutable, snapshot frequently
- **datapool = User Data** - Separate pool for data that changes often
- **Single Snapshot = Full System** - One snapshot captures entire OS state
- **Simple Rollback** - No dataset dependencies, just rollback one dataset

## 🔍 What Makes This Different?

### vs. Standard Ubuntu ZFS Install
- No zsys (simpler, more predictable)
- Monolithic structure (vs. multiple datasets)
- ZFSBootMenu instead of GRUB (boot from any snapshot)
- Partition-based (leaves room for datapool)

## 🎯 Common Use Cases

### 1. Development Server
```bash
# Take snapshot before making changes
sudo zfs snapshot rpool/ROOT/ubuntu-1@before-experiment

# Make changes, test...

# Rollback if needed (from ZFSBootMenu at boot)
# Or from running system:
sudo zfs rollback rpool/ROOT/ubuntu-1@before-experiment
sudo reboot
```

### 2. Production Server with Backups
```bash
# Set up automated backups with Syncoid
cat > /usr/local/bin/backup-system.sh << 'EOF'
#!/bin/bash
syncoid --no-sync-snap rpool/ROOT/ubuntu-1 backup-server:backup/$(hostname)-rpool
EOF
chmod +x /usr/local/bin/backup-system.sh

# Add to crontab (daily at 2 AM)
echo "0 2 * * * /usr/local/bin/backup-system.sh" | sudo crontab -
```

### 3. Desktop with Easy System Recovery
- Automatic snapshots before every update
- Boot into ZFSBootMenu if update breaks something
- Select previous snapshot and boot
- System restored to pre-update state

## 📸 Snapshot Management

### Automatic Snapshots (Sanoid)
- **Hourly:** Keep 36 (1.5 days)
- **Daily:** Keep 30 (1 month)
- **Monthly:** Keep 6 (6 months)

### Manual Snapshots
```bash
# Quick snapshot
sudo zfs snapshot rpool/ROOT/ubuntu-1@manual-$(date +%Y%m%d-%H%M)

# Before major change
sudo zfs snapshot rpool/ROOT/ubuntu-1@before-major-upgrade

# View all snapshots
zfs list -t snapshot

# Delete old snapshot
sudo zfs destroy rpool/ROOT/ubuntu-1@old-snapshot
```

### APT Hook (Automatic)
```bash
# Automatically runs before 'apt upgrade':
# Creates snapshot: rpool/ROOT/ubuntu-1@apt-2024-12-03-140530
```

## 🔧 Daily Operations

### System Updates
```bash
# Updates automatically create snapshots via APT hook
sudo apt update && sudo apt upgrade

# After kernel updates, regenerate ZFSBootMenu
sudo update-zbm
```

### Check System Health
```bash
# Pool status
sudo zpool status

# Snapshot space usage
zfs list -t snapshot -o name,used,referenced

# Sanoid status
systemctl status sanoid.timer
journalctl -u sanoid.service -n 20
```

### Network Configuration
```bash
# Default: DHCP on all interfaces
# To configure static IP:
sudo nano /etc/netplan/01-netcfg.yaml
sudo netplan apply
```

## 🚨 Recovery

### Boot from Snapshot (Most Common)
1. Reboot into ZFSBootMenu
2. Press `Ctrl+S` to view snapshots
3. Select snapshot to boot
4. Press `Ctrl+X` to "clone and promote" (makes it permanent)

### Emergency Recovery from Live USB
```bash
# Boot Ubuntu Live USB
sudo apt update && sudo apt install zfsutils-linux

# Import pool
sudo zpool import -f -R /mnt rpool
sudo zfs mount rpool/ROOT/ubuntu-1

# Chroot and fix
sudo mount --rbind /dev /mnt/dev
sudo mount --rbind /proc /mnt/proc
sudo mount --rbind /sys /mnt/sys
sudo chroot /mnt

# Make fixes, then exit
exit
sudo umount -R /mnt
sudo zpool export rpool
reboot
```

## ⚠️ Security Considerations

### Default Configuration
- ❌ **Weak Default Passwords** - root:root, user:username - CHANGE IMMEDIATELY!
- ❌ **No Firewall** - SSH exposed without firewall
- ❌ **No Encryption** - rpool is unencrypted (by design for simplicity)
- ✅ **SSH Enabled** - For remote access

### Recommended Hardening
```bash
# 1. Change passwords (CRITICAL)
passwd
sudo passwd root

# 2. Enable firewall
sudo apt install ufw
sudo ufw allow ssh
sudo ufw enable

# 3. Set up SSH keys (disable password auth)
# Copy your SSH public key to ~/.ssh/authorized_keys
sudo nano /etc/ssh/sshd_config
# Set: PasswordAuthentication no
sudo systemctl restart ssh

# 4. Encrypt datapool (optional)
sudo zfs create -o encryption=on -o keyformat=passphrase datapool/encrypted
```

## 🐛 Troubleshooting

### Installation Fails with "Invalid USERNAME"
- Username must be lowercase
- Can only contain letters, numbers, underscores, dashes
- Must start with letter or underscore
- Example: `admin`, `john_doe`, `user123`

### Installation Fails with "Disk is too small"
- Check disk size requirements in script
- Default: 91GB minimum (80GB rpool + 8GB swap + 1GB EFI + 2GB buffer)
- Edit `RPOOL_SIZE` in script if needed

### Network Not Working After Boot
```bash
# Check IP address
ip addr show

# Check network config
cat /etc/netplan/01-netcfg.yaml

# Apply network config
sudo netplan apply

# Test connectivity
ping -c 3 8.8.8.8
```

### ZFSBootMenu Not Appearing
- Check UEFI boot mode (not legacy BIOS)
- Verify EFI boot entry: `efibootmgr`
- Verify ZFSBootMenu file exists: `ls /boot/efi/EFI/ZBM/`

## 📊 Performance Tips

### For SSDs
```bash
# Enable autotrim (already done by script)
sudo zpool set autotrim=on rpool

# Verify
zpool get autotrim rpool
```

### For Large Memory Systems
```bash
# Limit ARC size (if needed)
echo "options zfs zfs_arc_max=8589934592" | sudo tee -a /etc/modprobe.d/zfs.conf
# (This sets max ARC to 8GB)
sudo update-initramfs -u -k all
```

### Regular Maintenance
```bash
# Monthly scrub (checks data integrity)
sudo zpool scrub rpool

# Weekly snapshot cleanup (automatic via Sanoid)
sudo sanoid --prune-snapshots --verbose
```

## 🤝 Contributing

Contributions welcome! Areas for improvement:
- [ ] Random password generation
- [ ] Static IP configuration prompts
- [ ] Firewall setup
- [ ] SSH key configuration
- [ ] Optional rpool encryption
- [ ] Support for other distributions

## 📝 License

MIT License - See LICENSE file for details

## 🙏 Credits

- Based on community ZFSBootMenu installation guides
- Uses [ZFSBootMenu](https://github.com/zbm-dev/zfsbootmenu) by zbm-dev
- Uses [Sanoid](https://github.com/jimsalterjrs/sanoid) by Jim Salter
- OpenZFS project

## 📚 Additional Resources

- [OpenZFS Documentation](https://openzfs.github.io/openzfs-docs/)
- [ZFSBootMenu Documentation](https://docs.zfsbootmenu.org/)
- [Sanoid Documentation](https://github.com/jimsalterjrs/sanoid/wiki)
- [Ubuntu ZFS Guide](https://ubuntu.com/tutorials/setup-zfs-storage-pool)

## 💬 Support

For issues or questions:
1. Check [INSTALLATION-GUIDE.md](INSTALLATION-GUIDE.md)
2. Check [TEST-VALIDATION.md](TEST-VALIDATION.md) for known issues
3. Review error messages from validation functions
4. Open an issue on GitHub

## 🔄 Version History

### Version 3.0.4 (2026-03-03)
- 📄 Added MIT license file
- 📝 Documentation cleanup: removed historical v1/v2 comparisons, added disclaimer, fixed Sanoid template name bug in examples

### Version 3.0.3 (2026-03-03)
- 🔒 Encrypted swap (ephemeral random key per boot via crypttab)
- 📋 Persistent install log (`/var/log/zbm-install.log`, copied into installed system)
- ⚡ IPv4 preference for apt (avoids slow/unreachable IPv6 Ubuntu mirrors)
- 🛡️ EFI environment check at startup (fails fast on BIOS/legacy systems)
- 🗂️ `/tmp` mounted as tmpfs (not snapshotted, lower ZFS CoW overhead)
- 👥 User added to standard Ubuntu groups (`adm`, `cdrom`, `dip`, `plugdev`)
- 🔧 `mount --make-rslave` before unmounting (prevents propagation to live host)
- 🐛 APT transient errors now fatal (stale package lists abort install)

### Version 3.0.2 (2026-03-03)
- 🐛 Fixed 6 network issues (resolv.conf, systemd-networkd/resolved, netplan generate, locales, tzdata)

### Version 3.0.1 (2026-03-02)
- 🐛 Fixed `select_disk()` early exit under `set -e`
- 🛡️ EFI variable failure is now a warning; fallback UEFI path always written

### Version 3.0 (2025-12-03)
- 🐛 Fixed 14 critical/high/medium issues from v2.0
- ✨ Robust error checking and verification at every critical step

---

**⚠️ Remember:** This script will **destroy all data** on the target disk. Always backup important data first!
