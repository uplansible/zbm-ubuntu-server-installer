#!/bin/bash
set -euo pipefail

################################################################################
# Ubuntu Server 24.04 ZFSBootMenu Installation Script v3.0.4
# - Monolithic rpool structure (single dataset for easy rollback)
# - Partition-based layout (not whole disk)
# - Sanoid for snapshot management
# - No zsys
# - Manual datapool creation later
################################################################################

# CONFIGURATION VARIABLES - EDIT THESE
################################################################################
# NOTE: DISK is selected interactively at runtime
# NOTE: RPOOL_SIZE is computed at runtime from RPOOL_PERCENT
HOSTNAME="myserver"                    # System hostname
USERNAME="admin"                       # Primary user
USER_PASSWORD=""                       # Set interactively at runtime
TIMEZONE="Europe/Zurich"               # Timezone
LOCALE="en_US.UTF-8"                   # System locale

# Pool configuration
RPOOL_PERCENT=80                       # Percentage of remaining disk for rpool (1-99)
SWAP_SIZE="8G"                         # Swap partition size
EFI_SIZE="1G"                          # EFI partition size

# ZFS properties
COMPRESSION="lz4"                      # Compression algorithm

# Optional datapool configuration (set to empty string to skip)
DATAPOOL_NAME="ssdupl"                 # Name of the datapool (leave empty to skip auto-creation)
DATAPOOL_MOUNTPOINT="/mnt/ssdupl"      # Where to mount the datapool

################################################################################
# INTERACTIVE CONFIGURATION
################################################################################
configure_interactively() {
    echo ""
    echo "======================================================================"
    echo "=== Interactive Configuration ==="
    echo "Press Enter to accept the default value shown in [brackets]."
    echo "======================================================================"
    echo ""

    local input

    # Hostname
    read -rp "Hostname [$HOSTNAME]: " input
    if [[ -n "$input" ]]; then
        HOSTNAME="$input"
    fi

    # Username
    read -rp "Username [$USERNAME]: " input
    if [[ -n "$input" ]]; then
        USERNAME="$input"
    fi

    # Password (prompted silently, confirmed)
    while true; do
        read -rsp "Password for $USERNAME: " USER_PASSWORD
        echo ""
        read -rsp "Confirm password: " pw_confirm
        echo ""
        if [[ "$USER_PASSWORD" == "$pw_confirm" ]]; then
            break
        fi
        echo "Passwords do not match. Please try again."
    done

    # Timezone
    read -rp "Timezone [$TIMEZONE]: " input
    if [[ -n "$input" ]]; then
        TIMEZONE="$input"
    fi

    # Swap size - auto-detect RAM and suggest an appropriate size
    local ram_gb
    ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    local suggested_swap
    if [[ $ram_gb -le 2 ]]; then
        suggested_swap="2G"
    elif [[ $ram_gb -le 8 ]]; then
        suggested_swap="${ram_gb}G"
    else
        suggested_swap="8G"
    fi
    SWAP_SIZE="$suggested_swap"
    read -rp "Swap size (detected RAM: ${ram_gb}GB, suggested: ${suggested_swap}) [$suggested_swap]: " input
    if [[ -n "$input" ]]; then
        SWAP_SIZE="$input"
    fi

    # ZFS compression
    echo ""
    echo "ZFS compression options: lz4 (fast, good ratio) | zstd (better ratio, slower) | gzip (best ratio, slowest) | none"
    read -rp "ZFS compression (lz4/zstd/gzip/none) [$COMPRESSION]: " input
    if [[ -n "$input" ]]; then
        COMPRESSION="$input"
    fi

    # Datapool: ask yes/no first, then name if yes
    echo ""
    local datapool_yn
    if [[ -n "$DATAPOOL_NAME" ]]; then
        read -rp "Create a datapool? [Y/n]: " datapool_yn
        if [[ "$datapool_yn" =~ ^[Nn]$ ]]; then
            DATAPOOL_NAME=""
        else
            read -rp "  Datapool name [$DATAPOOL_NAME]: " input
            if [[ -n "$input" ]]; then
                DATAPOOL_NAME="$input"
            fi
        fi
    else
        read -rp "Create a datapool? [y/N]: " datapool_yn
        if [[ "$datapool_yn" =~ ^[Yy]$ ]]; then
            local default_dp="datapool"
            read -rp "  Datapool name [$default_dp]: " input
            DATAPOOL_NAME="${input:-$default_dp}"
        fi
    fi

    # Summary
    echo ""
    echo "======================================================================"
    echo "Configuration summary:"
    echo "  Hostname:     $HOSTNAME"
    echo "  Username:     $USERNAME"
    echo "  Password:     (set)"
    echo "  Timezone:     $TIMEZONE"
    echo "  Swap size:    $SWAP_SIZE"
    echo "  Compression:  $COMPRESSION"
    echo "  Datapool:     ${DATAPOOL_NAME:-<none>}"
    echo "======================================================================"
    echo ""
}

################################################################################
# INPUT VALIDATION
################################################################################
validate_inputs() {
    # Validate USERNAME (alphanumeric, dash, underscore only)
    if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Error: Invalid USERNAME '$USERNAME'. Must start with lowercase letter or underscore,"
        echo "       and contain only lowercase letters, numbers, underscores, and dashes."
        exit 1
    fi

    # Validate HOSTNAME (RFC 1123 compliant)
    if [[ ! "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        echo "Error: Invalid HOSTNAME '$HOSTNAME'. Must be 1-63 characters,"
        echo "       start/end with alphanumeric, contain only lowercase letters, numbers, and dashes."
        exit 1
    fi

    # Validate TIMEZONE (check if file exists)
    if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        echo "Error: Invalid TIMEZONE '$TIMEZONE'."
        echo "       File /usr/share/zoneinfo/$TIMEZONE does not exist."
        echo "       Example valid timezones: America/New_York, Europe/London, Asia/Tokyo"
        exit 1
    fi

    # Validate LOCALE format
    if [[ ! "$LOCALE" =~ ^[a-z]{2}_[A-Z]{2}\.[A-Z0-9-]+$ ]]; then
        echo "Error: Invalid LOCALE '$LOCALE'."
        echo "       Format should be: language_COUNTRY.encoding (e.g., en_US.UTF-8)"
        exit 1
    fi

    # Validate size format (must end with G, supports decimals)
    if [[ ! "$EFI_SIZE" =~ ^[0-9]+(\.[0-9]+)?[GM]$ ]]; then
        echo "Error: Invalid EFI_SIZE '$EFI_SIZE'."
        echo "       Must be in format: numberG or numberM (e.g., 1G, 512M, 1.5G)"
        exit 1
    fi

    if [[ ! "$SWAP_SIZE" =~ ^[0-9]+(\.[0-9]+)?[GM]$ ]]; then
        echo "Error: Invalid SWAP_SIZE '$SWAP_SIZE'."
        echo "       Must be in format: numberG or numberM (e.g., 8G, 16G, 8.5G)"
        exit 1
    fi

    if [[ ! "$RPOOL_PERCENT" =~ ^[0-9]+$ ]] || \
       [[ "$RPOOL_PERCENT" -lt 1 ]] || [[ "$RPOOL_PERCENT" -gt 99 ]]; then
        echo "Error: Invalid RPOOL_PERCENT '$RPOOL_PERCENT'. Must be an integer between 1 and 99."
        exit 1
    fi

    # Validate DATAPOOL_NAME if set (alphanumeric, dash, underscore only, no spaces)
    if [[ -n "$DATAPOOL_NAME" ]]; then
        if [[ ! "$DATAPOOL_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
            echo "Error: Invalid DATAPOOL_NAME '$DATAPOOL_NAME'."
            echo "       Must start with a letter and contain only letters, numbers, underscores, and dashes."
            echo "       No spaces allowed."
            exit 1
        fi
    fi

    # Validate COMPRESSION
    if [[ ! "$COMPRESSION" =~ ^(lz4|zstd|gzip|none)$ ]]; then
        echo "Error: Invalid COMPRESSION '$COMPRESSION'. Must be one of: lz4, zstd, gzip, none"
        exit 1
    fi
}

# Convert size strings (e.g., 1G, 512M, 1.5G) to GB as a decimal number
convert_to_gb() {
    local size=$1
    if [[ $size =~ ^([0-9]+(\.[0-9]+)?)G$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ $size =~ ^([0-9]+(\.[0-9]+)?)M$ ]]; then
        # Convert MB to GB (divide by 1024)
        echo "scale=2; ${BASH_REMATCH[1]} / 1024" | bc
    else
        echo "0"
    fi
}

validate_disk_size() {
    local disk=$1

    # Get disk size in bytes
    local disk_bytes=$(blockdev --getsize64 "$disk")
    local disk_gb=$((disk_bytes / 1024 / 1024 / 1024))

    local efi_gb=$(convert_to_gb "$EFI_SIZE")
    local swap_gb=$(convert_to_gb "$SWAP_SIZE")

    # Calculate minimum required space (EFI + Swap + 2GB buffer for alignment)
    # RPOOL_SIZE is not checked here — it's derived as a percentage of remaining space
    local required_gb=$(echo "$efi_gb + $swap_gb + 2" | bc)
    local required_gb_int=$(echo "$required_gb / 1" | bc)  # Integer for comparison

    echo "Disk size: ${disk_gb}GB"
    echo "Required space: ${required_gb}GB (EFI: ${efi_gb}GB, Swap: ${swap_gb}GB, buffer: 2GB)"

    if [[ $disk_gb -lt $required_gb_int ]]; then
        echo "Error: Disk is too small!"
        echo "       Disk size: ${disk_gb}GB"
        echo "       Required: ${required_gb}GB minimum"
        exit 1
    fi

    echo "Disk size validation passed."
}

################################################################################
# INTERACTIVE DISK AND SIZE SELECTION
################################################################################

# Present a numbered list of block devices and let the user choose one.
# Sets the global DISK variable (e.g., /dev/sda).
select_disk() {
    echo ""
    echo "======================================================================"
    echo "Available disks:"
    echo "======================================================================"

    # Collect non-loop, non-optical block devices
    local -a names sizes models
    local i=0
    while IFS= read -r line; do
        local name size model
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')
        names+=("$name")
        sizes+=("$size")
        models+=("$model")
        printf "  [%d] /dev/%-12s  %-8s  %s\n" "$((i + 1))" "$name" "$size" "$model"
        i=$(( i + 1 ))
    done < <(lsblk -d -o NAME,SIZE,MODEL --noheadings | grep -v '^loop\|^sr')

    if [[ ${#names[@]} -eq 0 ]]; then
        echo "Error: No suitable block devices found."
        exit 1
    fi

    echo ""
    local choice
    while true; do
        read -rp "Select disk number [1-${#names[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#names[@]} ]]; then
            break
        fi
        echo "Invalid selection. Please enter a number between 1 and ${#names[@]}."
    done

    DISK="/dev/${names[$((choice - 1))]}"
    echo "Selected disk: $DISK (${sizes[$((choice - 1))]})"
}

# Show a breakdown of available space and prompt for rpool percentage.
# Reads: DISK, EFI_SIZE, SWAP_SIZE, RPOOL_PERCENT (default)
# Sets: RPOOL_SIZE (e.g., "75G")
select_rpool_percent() {
    local disk=$1

    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$disk")
    local disk_gb=$((disk_bytes / 1024 / 1024 / 1024))

    local efi_gb swap_gb
    efi_gb=$(convert_to_gb "$EFI_SIZE")
    swap_gb=$(convert_to_gb "$SWAP_SIZE")

    # Remaining space after EFI, swap, and 2 GB alignment buffer
    local remaining_gb
    remaining_gb=$(echo "$disk_gb - $efi_gb - $swap_gb - 2" | bc)
    local remaining_gb_int
    remaining_gb_int=$(echo "$remaining_gb / 1" | bc)

    # Default rpool size from RPOOL_PERCENT
    local default_rpool_gb
    default_rpool_gb=$(echo "$remaining_gb * $RPOOL_PERCENT / 100" | bc)
    local default_rpool_gb_int
    default_rpool_gb_int=$(echo "$default_rpool_gb / 1" | bc)

    echo ""
    echo "======================================================================"
    echo "Disk space breakdown for $disk:"
    echo "  Total disk:          ${disk_gb}G"
    echo "  EFI partition:     - ${efi_gb}G"
    echo "  Swap partition:    - ${swap_gb}G"
    echo "  Alignment buffer:  - 2G"
    printf "  Available for rpool: %dG\n" "$remaining_gb_int"
    echo "======================================================================"
    printf "Default rpool size: %d%% = %dG\n" "$RPOOL_PERCENT" "$default_rpool_gb_int"
    echo ""

    local pct
    while true; do
        read -rp "Enter rpool percentage (1-99) [default: ${RPOOL_PERCENT}]: " pct
        # Use default if empty
        if [[ -z "$pct" ]]; then
            pct=$RPOOL_PERCENT
        fi
        # Validate integer 1-99
        if [[ ! "$pct" =~ ^[0-9]+$ ]] || \
           [[ "$pct" -lt 1 ]] || [[ "$pct" -gt 99 ]]; then
            echo "Invalid input. Please enter an integer between 1 and 99."
            continue
        fi

        local rpool_gb_calc
        rpool_gb_calc=$(echo "$remaining_gb * $pct / 100" | bc)
        local rpool_gb_int
        rpool_gb_int=$(echo "$rpool_gb_calc / 1" | bc)

        # Soft warning if result is less than 10 GB
        if [[ $rpool_gb_int -lt 10 ]]; then
            echo "Warning: ${pct}% of available space is only ${rpool_gb_int}G."
            echo "This may be too small for a functional system (recommended: at least 10G)."
            local yn
            read -rp "Continue anyway? [y/N]: " yn
            if [[ ! "$yn" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi

        RPOOL_SIZE="${rpool_gb_int}G"
        echo "rpool size set to: $RPOOL_SIZE"
        break
    done
}

# Display a full confirmation table of partition layout and system config.
# Requires DISK, EFI_SIZE, SWAP_SIZE, RPOOL_SIZE to be set.
# Exits cleanly (exit 0) if the user does not confirm.
show_disk_confirmation() {
    local disk=$1

    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$disk")
    local disk_gb=$((disk_bytes / 1024 / 1024 / 1024))

    local efi_gb swap_gb rpool_gb
    efi_gb=$(convert_to_gb "$EFI_SIZE")
    swap_gb=$(convert_to_gb "$SWAP_SIZE")
    rpool_gb=$(convert_to_gb "$RPOOL_SIZE")

    local datapool_gb
    datapool_gb=$(echo "$disk_gb - $efi_gb - $swap_gb - $rpool_gb - 2" | bc)
    local datapool_gb_int
    datapool_gb_int=$(echo "$datapool_gb / 1" | bc)
    # Clamp to 0 if negative (shouldn't happen, but be safe)
    if [[ $datapool_gb_int -lt 0 ]]; then datapool_gb_int=0; fi

    local datapool_label="${DATAPOOL_NAME:-<none>}"

    echo ""
    echo "======================================================================"
    echo "INSTALLATION SUMMARY"
    echo "======================================================================"
    echo ""
    echo "Target disk:  $disk  (${disk_gb}G total)"
    echo ""
    echo "Partition layout:"
    printf "  Partition 1 (EFI):      %s\n"     "$EFI_SIZE"
    printf "  Partition 2 (Swap):     %s\n"     "$SWAP_SIZE"
    printf "  Partition 3 (rpool):    %s\n"     "$RPOOL_SIZE"
    printf "  Partition 4 (datapool): ~%dG (remaining)\n" "$datapool_gb_int"
    echo ""
    echo "System configuration:"
    echo "  Hostname:     $HOSTNAME"
    echo "  Username:     $USERNAME"
    echo "  Timezone:     $TIMEZONE"
    echo "  Locale:       $LOCALE"
    echo "  Compression:  $COMPRESSION"
    echo "  Datapool:     $datapool_label"
    echo ""
    echo "======================================================================"
    echo "WARNING: ALL DATA ON $disk WILL BE PERMANENTLY DESTROYED!"
    echo "======================================================================"
    echo ""
    local confirm
    read -rp "Type 'YES' to confirm and begin installation: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

################################################################################
# INSTALLATION MODE
################################################################################
MODE="${1:-}"

if [[ -z "$MODE" ]]; then
    echo "Usage: $0 {initial|postreboot}"
    echo ""
    echo "  initial    - Run from live USB to install system"
    echo "  postreboot - Run after first boot to complete setup"
    exit 1
fi

################################################################################
# CLEANUP FUNCTION
################################################################################
cleanup_on_error() {
    echo ""
    echo "======================================================================"
    echo "Error: Installation failed! Cleaning up..."
    echo "======================================================================"

    # Prevent unmount propagation back to live host
    mount --make-rslave /mnt/dev  2>/dev/null || true
    mount --make-rslave /mnt/proc 2>/dev/null || true
    mount --make-rslave /mnt/sys  2>/dev/null || true

    # Unmount everything - handle busy mounts gracefully
    if ! umount -R /mnt 2>/dev/null; then
        # If recursive unmount fails, use lazy unmount for known busy mounts
        umount -l /mnt/sys/fs/cgroup 2>/dev/null || true
        umount -l /mnt/dev 2>/dev/null || true
        umount -l /mnt/proc 2>/dev/null || true
        umount -l /mnt/sys 2>/dev/null || true
        umount /mnt/boot/efi 2>/dev/null || true
        umount /mnt 2>/dev/null || true
    fi

    # Export pools if they exist
    zpool export rpool 2>/dev/null || true

    # Also export datapool if it was created during postreboot
    if [[ -n "${DATAPOOL_NAME:-}" ]]; then
        zpool export "$DATAPOOL_NAME" 2>/dev/null || true
    fi

    echo "Cleanup complete. Please check the errors above and try again."
}

################################################################################
# INITIAL INSTALLATION (Run from Live USB)
################################################################################
if [[ "$MODE" == "initial" ]]; then
    # Set up error trap
    trap cleanup_on_error ERR

    # Verify we're running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root"
        exit 1
    fi

    # Verify EFI boot environment
    if [[ ! -d /sys/firmware/efi ]]; then
        echo "Error: EFI boot environment not found."
        echo "This script requires UEFI firmware. BIOS/legacy boot is not supported."
        exit 1
    fi
    echo "  ✓ EFI boot environment confirmed"

    # Start logging all output to a persistent install log
    INSTALL_LOG="/var/log/zbm-install.log"
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    echo "Installation log: $INSTALL_LOG"

    echo "======================================================================"
    echo "Starting Ubuntu 24.04 ZFSBootMenu Installation"
    echo "======================================================================"

    echo ""
    echo "Step 1: Checking network connectivity..."
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 9.9.9.9 >/dev/null 2>&1; then
        echo "Error: No network connectivity detected!"
        echo "This script requires internet access for:"
        echo "  - Package downloads (apt, debootstrap)"
        echo "  - ZFSBootMenu git repository"
        echo "  - Zellij binary download"
        echo "Please check your network connection and try again."
        exit 1
    fi
    echo "  ✓ Network connectivity verified"

    # Prefer IPv4 for apt to avoid slow/unreachable IPv6 Ubuntu mirrors
    sed -i 's,#precedence ::ffff:0:0/96  100,precedence ::ffff:0:0/96  100,' /etc/gai.conf
    echo "  ✓ IPv4 preferred for apt (IPv6 workaround applied)"

    echo ""
    echo "Step 2: Installing prerequisites..."
    apt update
    apt install -y debootstrap gdisk zfs-initramfs bc

    # Interactively prompt for configuration values (after bc is installed for size validation)
    configure_interactively

    # Validate configuration inputs
    echo ""
    echo "Validating configuration..."
    validate_inputs
    echo "Configuration validated successfully."

    # Interactively select the target disk
    select_disk

    # Verify the selected disk block device exists
    if [[ ! -b "$DISK" ]]; then
        echo "Error: Disk $DISK not found after selection."
        exit 1
    fi

    # Validate that the disk is large enough for EFI + Swap + buffer
    echo ""
    echo "Validating disk size..."
    validate_disk_size "$DISK"

    # Interactively select rpool percentage and compute RPOOL_SIZE
    select_rpool_percent "$DISK"

    # Show full confirmation table and require explicit YES before destructive steps
    show_disk_confirmation "$DISK"

    # Verify ZFS module is loaded or can be loaded
    echo "Verifying ZFS module..."
    if ! lsmod | grep -q "^zfs "; then
        echo "ZFS module not loaded, attempting to load..."
        modprobe zfs || {
            echo "Error: Failed to load ZFS module!"
            echo "ZFS may not be available on this system."
            exit 1
        }
    fi
    if [[ ! -c /dev/zfs ]]; then
        echo "Error: /dev/zfs not found! ZFS is not properly installed."
        exit 1
    fi
    echo "  ✓ ZFS module loaded and /dev/zfs available"

    echo ""
    echo "Step 3: Partitioning disk $DISK..."

    # Check if any partitions on the disk are mounted
    echo "Checking for mounted partitions on $DISK..."
    if mount | grep -q "^$DISK"; then
        echo "Error: Disk $DISK has mounted partitions!"
        echo "Mounted partitions:"
        mount | grep "^$DISK"
        echo ""
        echo "Please unmount all partitions before running this script."
        echo "Example: umount ${DISK}*"
        exit 1
    fi
    echo "No mounted partitions found."

    sgdisk --zap-all "$DISK"
    sgdisk -n1:0:+${EFI_SIZE} -t1:EF00 "$DISK"      # EFI
    sgdisk -n2:0:+${SWAP_SIZE} -t2:8200 "$DISK"     # Swap
    sgdisk -n3:0:+${RPOOL_SIZE} -t3:BF00 "$DISK"    # rpool
    sgdisk -n4:0:0 -t4:BF00 "$DISK"                 # datapool (ZFS partition, ready for manual pool creation)

    # Wait for kernel to update partition table
    partprobe "$DISK"
    udevadm settle

    # Detect partition naming scheme (NVMe uses p1, SATA uses 1)
    if [[ "$DISK" =~ nvme|mmcblk|loop ]]; then
        PART_PREFIX="p"
    else
        PART_PREFIX=""
    fi

    # Set partition variables
    DISK_EFI="${DISK}${PART_PREFIX}1"
    DISK_SWAP="${DISK}${PART_PREFIX}2"
    DISK_RPOOL="${DISK}${PART_PREFIX}3"
    DISK_DATAPOOL="${DISK}${PART_PREFIX}4"

    # Verify all partitions were created successfully (with retry)
    echo "Verifying partitions were created..."
    MAX_RETRIES=5
    RETRY_DELAY=1
    for part in "$DISK_EFI" "$DISK_SWAP" "$DISK_RPOOL" "$DISK_DATAPOOL"; do
        retry=0
        while [[ ! -b "$part" ]] && [[ $retry -lt $MAX_RETRIES ]]; do
            echo "  Waiting for $part to appear (attempt $((retry + 1))/$MAX_RETRIES)..."
            sleep $RETRY_DELAY
            udevadm settle
            ((retry++))
        done

        if [[ ! -b "$part" ]]; then
            echo "Error: Partition $part was not created after $MAX_RETRIES retries!"
            echo "Partition table:"
            lsblk "$DISK" || true
            sgdisk -p "$DISK" || true
            exit 1
        fi
        echo "  ✓ $part exists"
    done
    echo "All partitions created successfully."

    # Wipe any existing filesystem signatures and ZFS labels
    echo "Clearing filesystem signatures..."
    wipefs -a "$DISK_EFI" 2>/dev/null || true
    wipefs -a "$DISK_SWAP" 2>/dev/null || true
    wipefs -a "$DISK_RPOOL" 2>/dev/null || true
    wipefs -a "$DISK_DATAPOOL" 2>/dev/null || true

    # Clear any ZFS labels specifically
    zpool labelclear -f "$DISK_RPOOL" 2>/dev/null || true
    zpool labelclear -f "$DISK_DATAPOOL" 2>/dev/null || true

    echo ""
    echo "Step 4: Creating ZFS root pool..."
    # Create rpool with monolithic structure
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl \
        -O atime=off \
        -O canmount=off \
        -O compression=${COMPRESSION} \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=on \
        -O xattr=sa \
        -O mountpoint=none \
        rpool "$DISK_RPOOL"

    # Create single monolithic root dataset
    zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT
    zfs create -o mountpoint=/ rpool/ROOT/ubuntu-1
    
    # Mount root
    zpool export rpool
    zpool import -N -R /mnt rpool
    zfs mount rpool/ROOT/ubuntu-1

    echo ""
    echo "Step 5: Formatting EFI partition..."
    mkfs.vfat -F32 "$DISK_EFI"
    mkdir -p /mnt/boot/efi
    mount "$DISK_EFI" /mnt/boot/efi

    echo ""
    echo "Step 6: Setting up swap..."
    # Swap will be encrypted at boot via crypttab (ephemeral random key per boot)
    # No mkswap needed — cryptsetup will format the swap device on each boot

    # Capture EFI UUID for stable fstab entry (robust against disk renaming)
    DISK_EFI_UUID=$(blkid -s UUID -o value "$DISK_EFI")

    echo ""
    echo "Step 7: Installing Ubuntu base system..."
    debootstrap noble /mnt https://archive.ubuntu.com/ubuntu

    # Verify debootstrap succeeded
    echo "Verifying debootstrap installation..."
    if [[ ! -x /mnt/bin/bash ]]; then
        echo "Error: debootstrap failed! /mnt/bin/bash not found or not executable."
        echo "This usually means network issues or repository problems."
        echo "Contents of /mnt:"
        ls -la /mnt/ || true
        exit 1
    fi
    if [[ ! -d /mnt/usr/bin ]]; then
        echo "Error: debootstrap incomplete! /mnt/usr/bin directory missing."
        exit 1
    fi
    echo "  ✓ debootstrap completed successfully"

    echo ""
    echo "Step 8: Configuring base system..."

    # Copy zpool.cache if it exists
    mkdir -p /mnt/etc/zfs
    if [[ -f /etc/zfs/zpool.cache ]]; then
        cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    else
        echo "Note: /etc/zfs/zpool.cache not found, will be generated on first boot"
    fi

    # Generate fstab (use UUIDs for robustness against disk renaming)
    cat > /mnt/etc/fstab << EOF
# /etc/fstab: static file system information
UUID=$DISK_EFI_UUID  /boot/efi       vfat      defaults    0 1
/dev/mapper/swap     none            swap      defaults    0 0
EOF

    # Configure encrypted swap with a random ephemeral key per boot
    cat > /mnt/etc/crypttab << EOF
swap  $DISK_SWAP  /dev/urandom  plain,swap,cipher=aes-xts-plain64:sha256,size=512
EOF

    # Set hostname
    echo "$HOSTNAME" > /mnt/etc/hostname
    cat > /mnt/etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME

# IPv6
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # Configure apt sources (using HTTPS for security)
    cat > /mnt/etc/apt/sources.list << EOF
deb https://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF

    # Configure basic network (DHCP on all interfaces)
    mkdir -p /mnt/etc/netplan
    cat > /mnt/etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: true
EOF
    chmod 600 /mnt/etc/netplan/01-netcfg.yaml

    # Set low swappiness to minimize swap usage under normal conditions
    cat > /mnt/etc/sysctl.d/99-swappiness.conf << 'EOF'
# Minimize swap usage - only swap under extreme memory pressure
# Value 1 = minimum (0 means swap only on OOM, which can cause instability)
vm.swappiness=1
EOF

    # Bind mount necessary filesystems
    mount --rbind /dev  /mnt/dev
    mount --rbind /proc /mnt/proc
    mount --rbind /sys  /mnt/sys

    # Copy resolv.conf from live host so chroot apt can resolve DNS
    cp /etc/resolv.conf /mnt/etc/resolv.conf

    echo ""
    echo "Step 9: Installing packages in chroot..."

    # Create chroot script with proper variable expansion
    # NOTE: Using unquoted EOF allows variable expansion (e.g., $LOCALE)
    cat > /mnt/tmp/chroot-install.sh << EOF
#!/bin/bash
set -euo pipefail

# Set locale
locale-gen "$LOCALE"
update-locale LANG="$LOCALE"

# Make transient apt errors fatal so stale package lists don't cause silent failures
echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/30apt_error_on_transient

# Update and install packages
apt update
apt install -y --no-install-recommends \
    locales \
    linux-generic \
    zfs-initramfs \
    zfsutils-linux \
    cryptsetup \
    openssh-server \
    curl \
    wget \
    vim \
    htop \
    net-tools \
    iproute2

# Configure ZFS in initramfs
echo "zfs" >> /etc/initramfs-tools/modules

# Update initramfs
update-initramfs -c -k all

# Enable network services required by the networkd renderer
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Mount /tmp as tmpfs (faster, not snapshotted, reduces ZFS CoW pressure)
# Use fstab instead of tmp.mount unit (unit may not exist in minimal debootstrap)
echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,size=2G 0 0" >> /etc/fstab

# Generate netplan backend config files so networkd has .network files on first boot
netplan generate

# Point /etc/resolv.conf at systemd-resolved stub resolver
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

EOF

    chmod +x /mnt/tmp/chroot-install.sh
    echo "Running package installation in chroot..."
    if ! chroot /mnt /tmp/chroot-install.sh; then
        echo "Error: Package installation in chroot failed!"
        echo "Check the output above for specific errors."
        rm /mnt/tmp/chroot-install.sh
        exit 1
    fi
    rm /mnt/tmp/chroot-install.sh
    echo "  ✓ Package installation completed"

    echo ""
    echo "Step 10: Creating user and setting passwords..."

    # Create user setup script with proper variable expansion
    # NOTE: Using unquoted EOF allows variable expansion (e.g., $USERNAME, $TIMEZONE)
    cat > /mnt/tmp/user-setup.sh << EOF
#!/bin/bash
set -euo pipefail

# Create user with sudo access and standard Ubuntu groups
useradd -m -s /bin/bash -G sudo,adm,cdrom,dip,plugdev "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "User '$USERNAME' created with sudo access."

# Lock root account
passwd -l root
echo "Root account locked. Use 'sudo -i' to get a root shell."

# Configure timezone
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

EOF

    chmod +x /mnt/tmp/user-setup.sh
    echo "Running user setup in chroot..."
    if ! chroot /mnt /tmp/user-setup.sh; then
        echo "Error: User setup in chroot failed!"
        echo "Check the output above for specific errors."
        rm /mnt/tmp/user-setup.sh
        exit 1
    fi
    rm /mnt/tmp/user-setup.sh
    echo "  ✓ User setup completed"

    echo ""
    echo "Step 11: Installing ZFSBootMenu..."

    # Install ZFSBootMenu from source in chroot with proper variable expansion
    # NOTE: Using unquoted EOF allows variable expansion (e.g., $DISK, $DISK_EFI)
    cat > /mnt/tmp/zbm-install.sh << EOF
#!/bin/bash
set -euo pipefail

# Store disk and partition variables for use in script
DISK="$DISK"
DISK_EFI="$DISK_EFI"

# Install dependencies for ZFSBootMenu compilation
echo "Installing ZFSBootMenu build dependencies..."
apt update
apt install -y --no-install-recommends \\
    bsdextrautils \\
    mbuffer \\
    libsort-versions-perl \\
    libboolean-perl \\
    libyaml-pp-perl \\
    git \\
    fzf \\
    make \\
    kexec-tools \\
    dracut-core \\
    cpio \\
    curl \\
    systemd-boot \\
    binutils \\
    efibootmgr

# Download and compile ZFSBootMenu from source
echo "Downloading ZFSBootMenu from GitHub..."
mkdir -p /usr/local/src/zfsbootmenu
cd /usr/local/src/zfsbootmenu

# Download specific ZFSBootMenu version (pinned for stability)
# Using v2.3.x release - update this version as needed
ZBM_VERSION="v2.3.0"
echo "  - Using ZFSBootMenu version: \$ZBM_VERSION"
git clone --depth 1 --branch "\$ZBM_VERSION" https://github.com/zbm-dev/zfsbootmenu .

# Compile and install ZFSBootMenu
echo "Compiling ZFSBootMenu..."
make core dracut
make install

# Configure ZFSBootMenu
echo "Configuring ZFSBootMenu..."
mkdir -p /etc/zfsbootmenu
# NOTE: Using quoted 'ZBMCONF' prevents variable expansion (literal config file)
cat > /etc/zfsbootmenu/config.yaml << 'ZBMCONF'
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  Timeout: 10

Components:
  Enabled: false

EFI:
  ImageDir: /boot/efi/EFI/ZBM
  Versions: false
  Enabled: true

Kernel:
  CommandLine: ro quiet loglevel=4
  Prefix: vmlinuz
ZBMCONF

# Generate ZFSBootMenu image
echo "Generating ZFSBootMenu image..."
generate-zbm --debug

# Verify the image was created
if [[ ! -f /boot/efi/EFI/ZBM/vmlinuz.EFI ]]; then
    echo "Error: ZFSBootMenu image not generated!"
    exit 1
fi
echo "ZFSBootMenu image created successfully"

# Create EFI boot entry
echo "Creating EFI boot entry..."
# Extract partition number from DISK_EFI with improved validation
# Handles: /dev/nvme0n1p1 -> 1, /dev/sda1 -> 1, /dev/mmcblk0p1 -> 1
if [[ "\$DISK_EFI" =~ (nvme|mmcblk|loop).*p([0-9]+)$ ]]; then
    # NVMe/MMC style: /dev/nvme0n1p1
    PART_NUM="\${BASH_REMATCH[2]}"
elif [[ "\$DISK_EFI" =~ [a-z]+([0-9]+)$ ]]; then
    # SATA/SAS style: /dev/sda1
    PART_NUM="\${BASH_REMATCH[1]}"
else
    echo "Error: Could not extract partition number from \$DISK_EFI"
    echo "Unexpected device naming format: \$DISK_EFI"
    exit 1
fi

# Validate partition number is reasonable (1-128)
if [[ ! "\$PART_NUM" =~ ^[0-9]+$ ]] || [[ "\$PART_NUM" -lt 1 ]] || [[ "\$PART_NUM" -gt 128 ]]; then
    echo "Error: Invalid partition number: \$PART_NUM"
    echo "Expected a number between 1 and 128"
    exit 1
fi

# Always install to the UEFI fallback path so the system boots even on
# firmware that does not support EFI variables (old systems, CSM, etc.)
echo "Installing ZFSBootMenu to UEFI fallback path..."
mkdir -p /boot/efi/EFI/BOOT
cp /boot/efi/EFI/ZBM/vmlinuz.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI
echo "  ✓ Fallback EFI path set: /EFI/BOOT/BOOTX64.EFI"

# Attempt to create a named EFI boot entry via efibootmgr.
# This requires EFI variable support (efivars/efivarfs) in the firmware.
# On older systems the call may fail; the fallback path above ensures the
# system still boots in that case.
echo "Using disk \$DISK partition \$PART_NUM"
if efibootmgr -c -d "\$DISK" -p "\$PART_NUM" -L "ZFSBootMenu" -l '\EFI\ZBM\vmlinuz.EFI' 2>&1; then
    # Set ZFSBootMenu as first boot priority
    echo "Setting ZFSBootMenu as first boot priority..."
    ZBM_BOOT_NUM=\$(efibootmgr | grep "ZFSBootMenu" | sed 's/Boot\([0-9A-F]*\).*/\1/')
    if [[ -n "\$ZBM_BOOT_NUM" ]]; then
        CURRENT_ORDER=\$(efibootmgr | grep "BootOrder:" | sed 's/BootOrder: //')
        NEW_ORDER=\$(echo "\$CURRENT_ORDER" | sed "s/\$ZBM_BOOT_NUM,\?//g" | sed "s/^,//")
        efibootmgr -o "\$ZBM_BOOT_NUM,\$NEW_ORDER"
        echo "  ✓ ZFSBootMenu set as first boot priority (Boot\$ZBM_BOOT_NUM)"
    else
        echo "WARNING: Could not determine ZFSBootMenu boot entry number"
    fi
else
    echo "WARNING: efibootmgr could not create a boot entry (EFI variables not supported)."
    echo "         The system will boot via the fallback path /EFI/BOOT/BOOTX64.EFI."
    echo "         You may need to select the boot device manually on first boot."
fi

# Create update-zbm wrapper
# NOTE: Using quoted 'WRAPPER_EOF' prevents variable expansion (literal wrapper script)
cat > /usr/local/bin/update-zbm << 'WRAPPER_EOF'
#!/bin/bash
echo "Regenerating ZFSBootMenu..."
generate-zbm --debug
echo "ZFSBootMenu updated successfully"
WRAPPER_EOF
chmod +x /usr/local/bin/update-zbm

echo "ZFSBootMenu installation complete"

EOF

    chmod +x /mnt/tmp/zbm-install.sh
    echo "Running ZFSBootMenu installation in chroot..."
    if ! chroot /mnt /tmp/zbm-install.sh; then
        echo "Error: ZFSBootMenu installation in chroot failed!"
        echo "Check the output above for specific errors."
        rm /mnt/tmp/zbm-install.sh
        exit 1
    fi
    rm /mnt/tmp/zbm-install.sh
    echo "  ✓ ZFSBootMenu installation completed"

    echo ""
    echo "Step 12: Configuring SSH..."
    chroot /mnt systemctl enable ssh

    echo ""
    echo "Step 13: Setting ZFS properties for boot..."
    zpool set bootfs=rpool/ROOT/ubuntu-1 rpool

    echo ""
    echo "Step 14: Verifying installation..."

    # Verify ZFSBootMenu kernel image exists
    if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz.EFI ]]; then
        echo "Error: ZFSBootMenu kernel image not found!"
        echo "Expected: /mnt/boot/efi/EFI/ZBM/vmlinuz.EFI"
        exit 1
    fi
    echo "  ✓ ZFSBootMenu kernel image exists"

    # Verify bootfs property is set
    bootfs=$(zpool get -H -o value bootfs rpool)
    if [[ "$bootfs" != "rpool/ROOT/ubuntu-1" ]]; then
        echo "Error: bootfs property not set correctly!"
        exit 1
    fi
    echo "  ✓ bootfs property set correctly"

    # Verify EFI boot entry or fallback path exists
    if [[ -f /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
        echo "  ✓ UEFI fallback path present (/EFI/BOOT/BOOTX64.EFI)"
    elif efibootmgr 2>/dev/null | grep -q "ZFSBootMenu"; then
        echo "  ✓ EFI boot entry created"
    else
        echo "WARNING: Neither fallback EFI path nor efibootmgr entry found. Manual boot setup may be required."
    fi

    # Verify netplan config exists
    if [[ ! -f /mnt/etc/netplan/01-netcfg.yaml ]]; then
        echo "WARNING: Network configuration not found!"
    else
        echo "  ✓ Network configuration exists"
    fi

    echo "Installation verification complete."

    echo ""
    echo "Step 15: Copying installation script for post-reboot..."
    cp "$0" /mnt/root/
    chmod +x /mnt/root/$(basename "$0")

    # Copy install log into new system so it survives after reboot
    mkdir -p /mnt/var/log 2>/dev/null || true
    cp "$INSTALL_LOG" /mnt/var/log/zbm-install.log 2>/dev/null || true

    echo ""
    echo "Step 16: Unmounting and exporting pool..."

    # Prevent unmount propagation back to live host
    mount --make-rslave /mnt/dev  2>/dev/null || true
    mount --make-rslave /mnt/proc 2>/dev/null || true
    mount --make-rslave /mnt/sys  2>/dev/null || true

    # Unmount in specific order to handle busy mounts
    # Some mounts like cgroup may be busy, so we use lazy unmount as fallback
    if ! umount -R /mnt 2>/dev/null; then
        echo "  Note: Some mounts were busy, using lazy unmount..."
        umount -l /mnt/sys/fs/cgroup 2>/dev/null || true
        umount -l /mnt/dev 2>/dev/null || true
        umount -l /mnt/proc 2>/dev/null || true
        umount -l /mnt/sys 2>/dev/null || true
        umount /mnt/boot/efi 2>/dev/null || true
        umount /mnt 2>/dev/null || true
    fi

    zpool export rpool

    echo ""
    echo "======================================================================"
    echo "Initial installation complete!"
    echo "======================================================================"
    echo ""
    echo "IMPORTANT:"
    echo "  - User: $USERNAME (sudo enabled)"
    echo "  - Root account is LOCKED. Use 'sudo -i' for a root shell."
    echo ""
    echo "Next steps:"
    echo "  1. Remove the USB drive"
    echo "  2. Reboot the system"
    echo "  3. Login as $USERNAME"
    echo "  4. Run: sudo /root/$(basename "$0") postreboot"
    echo ""
    echo "Reboot now? (y/n)"
    read -r response
    if [[ "$response" == "y" ]]; then
        reboot
    fi

################################################################################
# POST-REBOOT SETUP
################################################################################
elif [[ "$MODE" == "postreboot" ]]; then
    echo "======================================================================"
    echo "Post-reboot setup - Installing Sanoid and configuring snapshots"
    echo "======================================================================"

    # Verify we're running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root"
        exit 1
    fi

    validate_inputs
    echo "Configuration validated successfully."

    echo ""
    echo "Step 0: Checking network connectivity..."
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 9.9.9.9 >/dev/null 2>&1; then
        echo "Error: No network connectivity detected!"
        echo "Please check your network connection and try again."
        exit 1
    fi
    echo "  ✓ Network connectivity verified"

    # Set up error handling for postreboot mode
    cleanup_postreboot() {
        echo ""
        echo "======================================================================"
        echo "Error: Post-reboot setup failed!"
        echo "======================================================================"

        # Try to export datapool if it was partially created
        if [[ -n "${DATAPOOL_NAME:-}" ]]; then
            zpool export "$DATAPOOL_NAME" 2>/dev/null || true
        fi

        echo "The system is bootable but snapshot management may not be configured."
        echo "Please check the errors above and fix manually or re-run this script."
    }
    trap cleanup_postreboot ERR

    echo ""
    echo "Step 1: Installing Sanoid..."
    apt update
    apt install -y sanoid

    echo ""
    echo "Step 2: Configuring Sanoid for rpool..."

    # Ensure sanoid config directory exists
    mkdir -p /etc/sanoid

    # NOTE: Using quoted 'EOF' prevents variable expansion (literal Sanoid config)
    cat > /etc/sanoid/sanoid.conf << 'EOF'
# Sanoid configuration for monolithic rpool

[rpool/ROOT/ubuntu-1]
    use_template = template_production
    recursive = yes

#############################
# Templates
#############################
[template_production]
    frequently = 0
    hourly = 36
    daily = 30
    monthly = 6
    yearly = 0
    autosnap = yes
    autoprune = yes
EOF

    echo ""
    echo "Step 3: Enabling Sanoid timer..."
    systemctl enable --now sanoid.timer

    echo ""
    echo "Step 4: Taking initial snapshot..."
    sanoid --take-snapshots --verbose

    echo ""
    echo "Step 5: Setting up APT hook for pre-update snapshots..."

    # NOTE: Using quoted 'EOF' prevents variable expansion (literal APT hook config)
    cat > /etc/apt/apt.conf.d/80-zfs-snapshot << 'EOF'
// Take ZFS snapshot before package upgrades
DPkg::Pre-Invoke {"if command -v zfs >/dev/null 2>&1; then zfs snapshot rpool/ROOT/ubuntu-1@apt-$(date +%Y-%m-%d-%H%M%S) || true; fi";};
EOF

    echo ""
    echo "Step 5a: Installing APT snapshot cleanup script..."

    # Create cleanup script
    cat > /usr/local/bin/cleanup-apt-snapshots.sh << 'EOF'
#!/bin/bash
# Cleanup old APT ZFS snapshots — keeps at most KEEP_COUNT newest

set -euo pipefail

DATASET="rpool/ROOT/ubuntu-1"
SNAPSHOT_PREFIX="apt-"
KEEP_COUNT=10

# Get all apt snapshots sorted newest-first
snapshots=$(zfs list -H -t snapshot -o name -S creation "${DATASET}" | grep "@${SNAPSHOT_PREFIX}[0-9]" || true)

if [[ -z "$snapshots" ]]; then
    total=0
else
    total=$(echo "$snapshots" | wc -l)
fi

echo "Found ${total} APT snapshot(s) on ${DATASET}"
logger -t cleanup-apt-snapshots "Found ${total} APT snapshots on ${DATASET}"

if [[ $total -le $KEEP_COUNT ]]; then
    echo "No cleanup needed (keeping last ${KEEP_COUNT} snapshots)"
    logger -t cleanup-apt-snapshots "No cleanup needed"
    exit 0
fi

to_delete=$((total - KEEP_COUNT))
echo "Deleting ${to_delete} old snapshot(s) (keeping newest ${KEEP_COUNT})..."

# tail gets the oldest snapshots (list is newest-first)
to_delete_list=$(echo "$snapshots" | tail -n "$to_delete")

while IFS= read -r snapshot; do
    if [[ -n "$snapshot" ]]; then
        echo "  Deleting: $snapshot"
        zfs destroy "$snapshot"
    fi
done <<< "$to_delete_list"

echo "Cleanup complete!"
logger -t cleanup-apt-snapshots "Cleanup complete: deleted ${to_delete} snapshots"
EOF

    chmod +x /usr/local/bin/cleanup-apt-snapshots.sh

    # Create systemd service
    cat > /etc/systemd/system/cleanup-apt-snapshots.service << 'EOF'
[Unit]
Description=Cleanup old APT ZFS snapshots
Documentation=man:zfs(8)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cleanup-apt-snapshots.sh
StandardOutput=journal
StandardError=journal
EOF

    # Create systemd timer (runs every 12 hours)
    cat > /etc/systemd/system/cleanup-apt-snapshots.timer << 'EOF'
[Unit]
Description=Twice-daily cleanup of old APT ZFS snapshots
Documentation=man:zfs(8)

[Timer]
OnCalendar=*-*-* 00,12:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Enable and start timer
    systemctl daemon-reload
    systemctl enable --now cleanup-apt-snapshots.timer

    echo "  ✓ APT snapshot cleanup configured (keeps last 10 snapshots, runs every 12 hours)"

    echo ""
    echo "Step 6: Installing additional useful tools..."
    apt install -y \
        ubuntu-server \
        pv \
        mbuffer \
        ncdu

    echo ""
    echo "Step 6a: Installing Zellij terminal multiplexer..."
    # Install Zellij from official release
    ZELLIJ_VERSION=$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest | grep -Po '"tag_name": "v\K[^"]*')

    # Validate version format (should be X.Y.Z)
    if [[ -z "$ZELLIJ_VERSION" ]] || [[ ! "$ZELLIJ_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Warning: Could not fetch valid Zellij version (got: '$ZELLIJ_VERSION'), using v0.40.1 as fallback"
        ZELLIJ_VERSION="0.40.1"
    fi
    echo "  - Installing Zellij version $ZELLIJ_VERSION"

    # Detect architecture for Zellij download
    ZELLIJ_ARCH=$(uname -m)
    case "$ZELLIJ_ARCH" in
        x86_64)  ZELLIJ_ARCH_SUFFIX="x86_64-unknown-linux-musl" ;;
        aarch64) ZELLIJ_ARCH_SUFFIX="aarch64-unknown-linux-musl" ;;
        *)
            echo "  ⚠ Warning: Unsupported architecture '$ZELLIJ_ARCH', skipping Zellij installation"
            ZELLIJ_SKIP=true ;;
    esac

    # Try to download Zellij, with error handling
    if [[ "${ZELLIJ_SKIP:-false}" != "true" ]]; then
        if ! curl -L "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-${ZELLIJ_ARCH_SUFFIX}.tar.gz" -o /tmp/zellij.tar.gz; then
            echo "  ⚠ Warning: Failed to download Zellij, skipping installation..."
            ZELLIJ_SKIP=true
        else
            ZELLIJ_SKIP=false
        fi
    fi

    if [[ "${ZELLIJ_SKIP:-false}" != "true" ]]; then
        tar -xzf /tmp/zellij.tar.gz -C /tmp
        mv /tmp/zellij /usr/local/bin/
        chmod +x /usr/local/bin/zellij
        rm /tmp/zellij.tar.gz

        # Verify installation
        if command -v zellij >/dev/null 2>&1; then
            echo "  ✓ Zellij installed successfully: $(zellij --version)"
        else
            echo "  ⚠ Warning: Zellij installation failed, but continuing..."
        fi
    fi

    # Optional: Create datapool if configured
    if [[ -n "$DATAPOOL_NAME" ]]; then
        echo ""
        echo "Step 7: Creating datapool '$DATAPOOL_NAME'..."

        # Detect partition naming
        if [[ "$DISK" =~ nvme|mmcblk|loop ]]; then
            PART_PREFIX="p"
        else
            PART_PREFIX=""
        fi
        DATAPOOL_PARTITION="${DISK}${PART_PREFIX}4"

        # Partition type is already BF00 (set during initial install)
        # Verify partition exists
        if [[ ! -b "$DATAPOOL_PARTITION" ]]; then
            echo "Error: Datapool partition $DATAPOOL_PARTITION not found!"
            echo "Available partitions:"
            lsblk "$DISK" || true
            exit 1
        fi
        echo "  - Using partition: $DATAPOOL_PARTITION"

        # Create mount point
        echo "  - Creating mount point: $DATAPOOL_MOUNTPOINT"
        mkdir -p "$DATAPOOL_MOUNTPOINT"

        # Create the pool
        echo "  - Creating ZFS pool: $DATAPOOL_NAME"
        zpool create -o ashift=12 \
                     -O compression=lz4 \
                     -O atime=off \
                     -O mountpoint="$DATAPOOL_MOUNTPOINT" \
                     "$DATAPOOL_NAME" "$DATAPOOL_PARTITION"

        echo "  ✓ Datapool '$DATAPOOL_NAME' created and mounted at $DATAPOOL_MOUNTPOINT"

        # Add to Sanoid config
        echo ""
        echo "  - Adding datapool to Sanoid configuration..."
        cat >> /etc/sanoid/sanoid.conf << EOF

[$DATAPOOL_NAME]
    use_template = template_production
    recursive = yes
EOF
        echo "  ✓ Sanoid configured for $DATAPOOL_NAME"
    else
        echo ""
        echo "Step 7: Skipping datapool creation (DATAPOOL_NAME not set)"
    fi

    echo ""
    echo "======================================================================"
    echo "Post-reboot setup complete!"
    echo "======================================================================"
    echo ""
    echo "Your system is now ready. Summary:"
    echo ""
    echo "  - Monolithic rpool: rpool/ROOT/ubuntu-1"
    if [[ -n "$DATAPOOL_NAME" ]]; then
        echo "  - Datapool '$DATAPOOL_NAME' created and mounted at $DATAPOOL_MOUNTPOINT"
    else
        echo "  - Datapool partition ready: Check with 'lsblk' (likely ${DISK}p4 or ${DISK}4)"
    fi
    echo "  - Sanoid configured for hourly/daily/monthly snapshots"
    echo "  - APT hook creates snapshots before updates (keeps last 10, cleaned weekly)"
    echo "  - ZFSBootMenu installed and configured"
    echo ""
    echo "Next steps:"
    echo "  1. Use 'passwd' to change your password if needed"
    if [[ -n "$DATAPOOL_NAME" ]]; then
        echo "  2. Create datasets in $DATAPOOL_NAME as needed:"
        echo "     zfs create $DATAPOOL_NAME/docker"
        echo "     zfs create $DATAPOOL_NAME/services"
    else
        echo "  2. Create your datapool manually when ready:"
        echo "     First, identify your datapool partition with: lsblk"
        echo "     Then: zpool create -o ashift=12 -O compression=lz4 datapool /dev/PARTITION"
        echo "  3. Create datasets in datapool as needed:"
        echo "     zfs create datapool/docker"
        echo "     zfs create datapool/services"
        echo "  4. Configure datapool in /etc/sanoid/sanoid.conf"
    fi
    echo ""
    echo "Snapshot management:"
    echo "  - View snapshots: zfs list -t snapshot"
    echo "  - Manual snapshot: zfs snapshot rpool/ROOT/ubuntu-1@manual"
    echo "  - Rollback: reboot -> ZFSBootMenu -> select snapshot -> Ctrl+X"
    echo ""
    echo "For syncoid backups to another machine:"
    echo "  syncoid rpool/ROOT/ubuntu-1 backup-server:backup/rpool"
    echo ""

else
    echo "Invalid mode: $MODE"
    echo "Usage: $0 {initial|postreboot}"
    exit 1
fi
