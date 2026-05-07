# Ubuntu 26.04 ZFSBootMenu Server Installation

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ubuntu 26.04](https://img.shields.io/badge/Ubuntu-26.04%20LTS-orange.svg)](https://ubuntu.com)
[![ZFS](https://img.shields.io/badge/ZFS-OpenZFS-blue.svg)](https://openzfs.org)

Automated installation script for Ubuntu 26.04 Server with ZFS root filesystem and ZFSBootMenu bootloader. Features a monolithic ZFS architecture optimized for easy snapshots and system rollbacks.

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
- Ubuntu 26.04 Live USB
- Target disk with at least 90GB (default: 1GB EFI + swap sized to RAM + 80% of remaining for rpool)
- Internet connection
- UEFI boot mode (required for ZFSBootMenu)

### Installation (5 minutes + download time)

1. **Boot Ubuntu 26.04 Live USB**

2. **Download and run:**

   > **Review before running:** This script will **permanently destroy all data** on the target disk. It is good practice to read the script before executing it: [zbm-ubuntu-server-installer.sh](https://github.com/uplansible/zbm-ubuntu-server-installer/blob/main/zbm-ubuntu-server-installer.sh)

   To download the script and execute it, use the convenient one-liner:
   ```bash
   wget -qO zbm-ubuntu-server-installer.sh https://raw.githubusercontent.com/uplansible/zbm-ubuntu-server-installer/main/zbm-ubuntu-server-installer.sh && chmod +x zbm-ubuntu-server-installer.sh && sudo ./zbm-ubuntu-server-installer.sh initial
   ```

   All configuration is collected interactively — no script editing required. You will be prompted for:
   - **Disk** — select from detected disks
   - **Disk setup mode** — single disk (rpool + datapool share one disk) or separate disks (rpool on install disk, datapool on other disk(s))
   - **Hostname**, **Username**, **Password**
   - **Timezone** — e.g. `Europe/Zurich`
   - **Locale** — e.g. `en_GB.UTF-8`
   - **Swap size** — auto-suggested based on detected RAM
   - **ZFS compression** — lz4 / zstd / gzip / none
   - **Keyboard layout** — auto-detected from live session, confirm or override
   - **Datapool** — optional second pool for user data

   Type `YES` to confirm the disk layout. Wait 15–30 minutes.

3. **Reboot and complete setup:**
   ```bash
   sudo ~/zbm-installer/zbm-ubuntu-server-installer.sh postreboot
   ```

## 📖 Documentation

- **[QUICK-REFERENCE.md](QUICK-REFERENCE.md)** - Common ZFS/Sanoid/Syncoid commands

## 🏗️ Architecture

### Disk Layout

Two modes are available, selected interactively during install:

**Single-disk mode** — rpool and datapool share the install disk:
```
Partition 1:  1GB         EFI System Partition
Partition 2:  auto (RAM)  Swap (encrypted, ephemeral key)
Partition 3:  80% of disk rpool (ZFS root)
Partition 4:  Rest        datapool (created in postreboot if configured)
```

**Separate-disks mode** — rpool on install disk, datapool on separate disk(s):
```
Install disk:
  Partition 1:  1GB         EFI System Partition
  Partition 2:  auto (RAM)  Swap (encrypted, ephemeral key)
  Partition 3:  100% rest   rpool (ZFS root)

Datapool disk(s): whole disks — single / mirror / raidz1 / raidz2 / raidz3
```

**ZFS Structure:**
```
rpool/ROOT/ubuntu-1        ← Monolithic dataset (root + /home + /var)
datapool/                  ← Optional separate data pool (configured during install)
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
- ✅ **No Default Passwords** - Password set interactively during installation; root account is locked
- ❌ **No Firewall** - SSH exposed without firewall
- ❌ **No Encryption** - rpool is unencrypted (by design for simplicity)
- ✅ **SSH Enabled** - openssh-server installed and active after first boot

### Recommended Hardening
```bash
# 1. Enable firewall
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
- Default: ~91GB minimum (80% of disk for rpool + swap + 1GB EFI + buffer)
- Adjust `RPOOL_PERCENT` (default: 80) in script if needed

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

### Dropped to Emergency Shell — "zpool: no such pool" or rpool not found

If ZFS initramfs cannot import `rpool` automatically (e.g. after a failed `postreboot` run
or unclean shutdown), you will be dropped to a BusyBox / ZFS emergency shell.

```bash
# Force-import rpool and continue boot
zpool import -f rpool
exit
```

If the pool still won't import, the partition may be visible but the cache stale:
```bash
# List available pools
zpool import
# Then force-import by name
zpool import -f rpool
exit
```

After the system boots, verify pool health and then reboot cleanly:
```bash
sudo zpool status
sudo reboot
```

### Ran out of Space in rpool

```bash
# Find which snapshots are using the most space
zfs list -t snapshot -o name,used -s used | head -20

# Delete a specific snapshot
sudo zfs destroy rpool/ROOT/ubuntu-1@old-snapshot

# Or let Sanoid prune according to its retention policy
sudo sanoid --prune-snapshots --verbose
```

### ZFSBootMenu Not Appearing
- Check UEFI boot mode (not legacy BIOS)
- Verify EFI boot entry: `efibootmgr`
- Verify ZFSBootMenu file exists: `ls /boot/efi/EFI/ZBM/`

### Testing in a VM (virt-manager / QEMU)

**Recommended firmware:** `OVMF_CODE_4M.fd` (4 MB NVRAM, no Secure Boot)

In virt-manager → VM Details → Overview → Firmware, select:
```
UEFI x86_64: /usr/share/OVMF/OVMF_CODE_4M.fd
```

Avoid these variants — they will prevent ZFSBootMenu from booting (unsigned binary):
- `OVMF_CODE_4M.ms.fd` / `OVMF_CODE_4M.md.fd` — Secure Boot with MS keys enrolled
- `OVMF_CODE.secboot.fd` — Secure Boot enabled
- `OVMF_CODE.amdsev.fd` — AMD SEV encryption (not relevant)

**After installation, before rebooting:**
- Detach the live ISO from the VM (Disk → right-click → Remove)
- Verify the EFI binary is present: `ls /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI`

**If you see TianoCore logo → "no bootable device":**
1. Confirm firmware is `OVMF_CODE_4M.fd` (not a secboot variant)
2. Press F2 at the TianoCore screen → Boot Manager → Boot From File → select the disk → `EFI\BOOT\BOOTX64.EFI` to test manually

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

## 📝 License

MIT License - See LICENSE file for details

## 🙏 Credits

- Inspired by [ubuntu-server-zfsbootmenu](https://github.com/Sithuk/ubuntu-server-zfsbootmenu) by [Sithuk](https://github.com/Sithuk)
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
1. Check [QUICK-REFERENCE.md](QUICK-REFERENCE.md) for common commands
2. Review error messages from validation functions
3. Open an issue on GitHub

## 🔄 Version History

### Version 3.0.48 (2026-05-07)
- 🗂️ Disk selection menu: selected disks are removed from the list after each pick (no duplicate-selection possible)

### Version 3.0.47 (2026-05-07)
- 🔧 Add `rd.driver.export=zfs` to ZFSBootMenu kernel command line (ensures ZFS driver exports cleanly on boot)

### Version 3.0.46 (2026-05-07)
- 📦 Add `systemd-timesyncd` to chroot package list so time sync is available immediately after first boot
- 🐛 Init `DISK_DATAPOOL=""` globally; guard `wipefs`/`labelclear` with `-n` check to prevent accidental wipe in dry-run mode

### Version 3.0.45 (2026-05-07)
- 🐛 Fix separate-disks mode incorrectly checking partition 4 when verifying rpool disk

### Version 3.0.44 (2026-05-07)
- 📝 Clarify end-of-initial-phase message with explicit postreboot task list

### Version 3.0.43 (2026-05-07)
- 🐛 Fix `local` keyword used outside a function in separate-disks `RPOOL_SIZE` calculation

### Version 3.0.42 (2026-05-07)
- ✨ Add `DISK_SETUP_MODE` — interactive prompt asks whether rpool and datapool share one disk or use separate disks; datapool topology (single / mirror / raidz1 / raidz2 / raidz3) selectable for multi-disk setups

### Version 3.0.41 (2026-05-06)
- 🐛 Fix EFI boot order entry with trailing comma, resolve `resolv.conf` symlink ordering, add keyboard layout validation

### Version 3.0.40 (2026-05-06)
- 🔒 User password no longer written to disk — set via `chpasswd` stdin pipe after chroot; safe for all metacharacters
- 🛡️ Swap-size prompt validates numeric input before arithmetic expansion — non-numeric entry re-prompts instead of aborting
- 🐛 Locale search uses fixed-string grep (`-F`) — prevents regex metacharacters from crashing the search
- 🐛 Fixed invalid `cleanup-apt-snapshots.timer` `OnCalendar` expression — split into two valid lines so the timer loads correctly
- 🔁 ZFSBootMenu git clone is now idempotent — source directory is wiped before cloning, fixing `reinstall-zbm` mode

### Version 3.0.36 (2026-04-02)
- 🔁 Idempotent `postreboot`: datapool creation and Sanoid config now skip gracefully if already done (safe to run twice)
- 🔕 Mask `systemd-tpm2-setup-early.service` and `systemd-tpm2-setup.service` in chroot — eliminates boot FAILED noise on systems without TPM2
- 🐛 Fixed emergency ZFS shell on reboot caused by ERR trap exporting the datapool when `postreboot` was run a second time

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
