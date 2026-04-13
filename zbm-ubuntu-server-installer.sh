#!/bin/bash
set -Eeuo pipefail

################################################################################
# Ubuntu Server 24.04 ZFSBootMenu Installation Script v3.0.38
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
LOCALE="en_GB.UTF-8"                   # System locale (British English: metric units, 24h time)

# Pool configuration
RPOOL_PERCENT=80                       # Percentage of remaining disk for rpool (1-99)
SWAP_SIZE=8192                         # Swap partition size in MiB (set interactively based on RAM)
EFI_SIZE=1024                          # EFI partition size in MiB (1024 MiB = 1 GiB)

# ZFS properties
COMPRESSION="lz4"                      # Compression algorithm

# ZFS pool tuning
ASHIFT=12            # Sector alignment: 12=4K sectors (SSD/NVMe), 9=512B (legacy HDD)
ZFS_ATIME="off"      # Disable access-time updates for performance
ZFS_RELATIME="on"    # Relative atime (updates only if older than 1 day)

# Keyboard layout (set interactively at runtime from live session or manual entry)
KEYBOARD_LAYOUT="us"               # Keyboard layout code (e.g., us, ch, de, fr)
KEYBOARD_VARIANT=""                # Keyboard variant (e.g., fr for ch-fr, empty for default)

# APT mirror (selected at runtime by speed test; fallback to official archive)
APT_MIRROR="https://archive.ubuntu.com/ubuntu"

# Optional datapool configuration (set to empty string to skip)
DATAPOOL_NAME="ssdupl"                 # Name of the datapool (leave empty to skip auto-creation)

# Optional software
INSTALL_ZELLIJ="y"   # Install Zellij terminal multiplexer (y/n)
INSTALL_DOCKER="y"   # Install Docker Engine via official apt repo (y/n)

################################################################################
# LOCALE SEARCH
################################################################################
# Searches /usr/share/i18n/SUPPORTED for locales matching a user-supplied term.
# Sets the global LOCALE variable. Press Enter with no search term to keep default.
select_locale() {
    local supported_file="/usr/share/i18n/SUPPORTED"
    if [[ ! -f "$supported_file" ]]; then
        echo "Note: $supported_file not found, keeping locale: $LOCALE"
        return
    fi

    echo "Locale search — current default: $LOCALE"
    echo "Type a search term (e.g. 'de', 'ch', 'en_US') or press Enter to keep default."

    while true; do
        echo ""
        local term
        read -rp "Search locale (Enter to accept [$LOCALE]): " term

        # Empty input = keep current LOCALE
        if [[ -z "$term" ]]; then
            echo "  Keeping locale: $LOCALE"
            return
        fi

        # Search: extract first field (locale name), filter by term (case-insensitive)
        local -a results
        mapfile -t results < <(grep -i "$term" "$supported_file" | awk '{print $1}' | grep -v '^#')

        if [[ ${#results[@]} -eq 0 ]]; then
            echo "  No locales found matching '$term'. Try again."
            continue
        fi

        # Show up to 30 results to avoid flooding the terminal
        local display_count=${#results[@]}
        local truncated=false
        if [[ $display_count -gt 30 ]]; then
            display_count=30
            truncated=true
        fi

        echo ""
        for (( i=0; i<display_count; i++ )); do
            printf "  [%2d] %s\n" "$((i+1))" "${results[$i]}"
        done
        if $truncated; then
            echo "  ... (${#results[@]} total — refine your search to see more)"
        fi

        echo ""
        local choice
        read -rp "Select number, or press Enter to search again: " choice

        if [[ -z "$choice" ]]; then
            continue
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$display_count" ]]; then
            LOCALE="${results[$((choice-1))]}"
            echo "  Locale set to: $LOCALE"
            return
        fi

        echo "  Invalid selection. Press Enter to search again."
    done
}

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
    local suggested_swap_gib
    if [[ $ram_gb -le 2 ]]; then
        suggested_swap_gib=2
    elif [[ $ram_gb -le 8 ]]; then
        suggested_swap_gib=$ram_gb
    else
        suggested_swap_gib=8
    fi
    SWAP_SIZE=$(( suggested_swap_gib * 1024 ))
    read -rp "Swap size in GiB (detected RAM: ${ram_gb}GiB, suggested: ${suggested_swap_gib}GiB) [${suggested_swap_gib}]: " input
    if [[ -n "$input" ]]; then
        SWAP_SIZE=$(( input * 1024 ))
    fi

    # Locale (interactive search)
    echo ""
    select_locale

    # ZFS compression
    echo ""
    echo "ZFS compression options: lz4 (fast, good ratio) | zstd (better ratio, slower) | gzip (best ratio, slowest) | none"
    read -rp "ZFS compression (lz4/zstd/gzip/none) [$COMPRESSION]: " input
    if [[ -n "$input" ]]; then
        COMPRESSION="$input"
    fi

    # Keyboard layout: detect from live session, offer to reuse
    echo ""
    local live_layout live_variant
    if [[ -f /etc/default/keyboard ]]; then
        live_layout=$(grep '^XKBLAYOUT=' /etc/default/keyboard | cut -d= -f2 | tr -d '"')
        live_variant=$(grep '^XKBVARIANT=' /etc/default/keyboard | cut -d= -f2 | tr -d '"')
    fi
    if [[ -n "$live_layout" ]]; then
        local kbd_display="$live_layout"
        [[ -n "$live_variant" ]] && kbd_display="$live_layout/$live_variant"
        read -rp "Use live-session keyboard layout ($kbd_display)? [Y/n]: " input
        if [[ ! "$input" =~ ^[Nn]$ ]]; then
            KEYBOARD_LAYOUT="$live_layout"
            KEYBOARD_VARIANT="${live_variant:-}"
        else
            read -rp "Keyboard layout [$KEYBOARD_LAYOUT]: " input
            [[ -n "$input" ]] && KEYBOARD_LAYOUT="$input"
            read -rp "Keyboard variant (leave blank for none) [${KEYBOARD_VARIANT:-}]: " input
            KEYBOARD_VARIANT="$input"
        fi
    else
        echo "No keyboard layout detected from live session."
        read -rp "Keyboard layout [$KEYBOARD_LAYOUT]: " input
        [[ -n "$input" ]] && KEYBOARD_LAYOUT="$input"
        read -rp "Keyboard variant (leave blank for none) [${KEYBOARD_VARIANT:-}]: " input
        KEYBOARD_VARIANT="$input"
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

    # Software
    echo ""
    echo "--- Software ---"
    read -rp "Install Zellij terminal multiplexer? [Y/n]: " input
    if [[ "$input" =~ ^[Nn]$ ]]; then INSTALL_ZELLIJ="n"; else INSTALL_ZELLIJ="y"; fi
    read -rp "Install Docker Engine (official apt repo, not snap)? [Y/n]: " input
    if [[ "$input" =~ ^[Nn]$ ]]; then INSTALL_DOCKER="n"; else INSTALL_DOCKER="y"; fi

    # Summary
    echo ""
    echo "======================================================================"
    echo "Configuration summary:"
    echo "  Hostname:     $HOSTNAME"
    echo "  Username:     $USERNAME"
    echo "  Password:     (set)"
    echo "  Timezone:     $TIMEZONE"
    echo "  Locale:       $LOCALE"
    echo "  Swap size:    $(( SWAP_SIZE / 1024 ))GiB"
    echo "  Compression:  $COMPRESSION"
    local kbd_summary="$KEYBOARD_LAYOUT"
    [[ -n "$KEYBOARD_VARIANT" ]] && kbd_summary="$KEYBOARD_LAYOUT/$KEYBOARD_VARIANT"
    echo "  Keyboard:     $kbd_summary"
    echo "  Datapool:     ${DATAPOOL_NAME:-<none>}"
    echo "  Zellij:       ${INSTALL_ZELLIJ}"
    echo "  Docker:       ${INSTALL_DOCKER}"
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

    # Validate EFI_SIZE (integer MiB, minimum 256 MiB)
    if [[ ! "$EFI_SIZE" =~ ^[0-9]+$ ]] || [[ "$EFI_SIZE" -lt 256 ]]; then
        echo "Error: Invalid EFI_SIZE '$EFI_SIZE'. Must be a positive integer in MiB (minimum 256)."
        exit 1
    fi

    # Validate SWAP_SIZE (integer MiB, minimum 512 MiB)
    if [[ ! "$SWAP_SIZE" =~ ^[0-9]+$ ]] || [[ "$SWAP_SIZE" -lt 512 ]]; then
        echo "Error: Invalid SWAP_SIZE '$SWAP_SIZE'. Must be a positive integer in MiB (minimum 512)."
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

    # Derive datapool mountpoint from pool name
    if [[ -n "$DATAPOOL_NAME" ]]; then
        DATAPOOL_MOUNTPOINT="/$DATAPOOL_NAME"
    fi

    # Validate COMPRESSION
    if [[ ! "$COMPRESSION" =~ ^(lz4|zstd|gzip|none)$ ]]; then
        echo "Error: Invalid COMPRESSION '$COMPRESSION'. Must be one of: lz4, zstd, gzip, none"
        exit 1
    fi
    fi
}

validate_disk_size() {
    local disk=$1

    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$disk")
    local disk_mib=$(( disk_bytes / 1024 / 1024 ))

    # Minimum required: EFI + Swap + 2 GiB alignment buffer
    local required_mib=$(( EFI_SIZE + SWAP_SIZE + 2048 ))

    echo "Disk size: $(( disk_mib / 1024 ))GiB"
    echo "Required:  $(( required_mib / 1024 ))GiB  (EFI: $(( EFI_SIZE / 1024 ))GiB, Swap: $(( SWAP_SIZE / 1024 ))GiB, buffer: 2GiB)"

    if [[ $disk_mib -lt $required_mib ]]; then
        echo "Error: Disk is too small!"
        echo "       Disk: $(( disk_mib / 1024 ))GiB,  Required: $(( required_mib / 1024 ))GiB minimum"
        exit 1
    fi

    echo "Disk size validation passed."
}

################################################################################
# INTERACTIVE DISK AND SIZE SELECTION
################################################################################

# Resolve a partition block device to its most stable available path.
# Priority: /dev/disk/by-id/ (ata-/nvme-, skips wwn-)
#        -> /dev/disk/by-partuuid/ (works on VMs with virtio disks)
#        -> raw device path (last resort)
resolve_part_byid() {
    local part
    part=$(readlink -f "$1")

    # Prefer by-id (physical disks: ata-, nvme-)
    local byid
    byid=$(find /dev/disk/by-id/ -maxdepth 1 -type l 2>/dev/null \
        | while read -r link; do
            [[ "$(readlink -f "$link")" == "$part" ]] && echo "$link"
          done \
        | grep -v "/wwn-" | sort | head -1) || true
    if [[ -n "$byid" ]]; then
        echo "$byid"
        return
    fi

    # Fall back to by-partuuid (stable on VMs with virtio/paravirtual disks)
    local bypartuuid
    bypartuuid=$(find /dev/disk/by-partuuid/ -maxdepth 1 -type l 2>/dev/null \
        | while read -r link; do
            [[ "$(readlink -f "$link")" == "$part" ]] && echo "$link"
          done | head -1) || true
    if [[ -n "$bypartuuid" ]]; then
        echo "$bypartuuid"
        return
    fi

    # Last resort: raw device path
    echo "$1"
}

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
        local name size model byid
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')
        byid=$(find /dev/disk/by-id/ -maxdepth 1 -type l 2>/dev/null \
            | while read -r link; do
                [[ "$(readlink -f "$link")" == "/dev/$name" ]] && echo "$link"
              done \
            | grep -v "/wwn-" | sort | head -1) || true
        byid="${byid##*/}"
        names+=("$name")
        sizes+=("$size")
        models+=("$model")
        printf "  [%d] /dev/%-10s  %-8s  %-28s  %s\n" \
            "$((i + 1))" "$name" "$size" "$model" "${byid:--}"
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
# Reads: DISK, EFI_SIZE, SWAP_SIZE (MiB), RPOOL_PERCENT (default)
# Sets: RPOOL_SIZE in MiB
select_rpool_percent() {
    local disk=$1

    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$disk")
    local disk_mib=$(( disk_bytes / 1024 / 1024 ))

    # Remaining space after EFI, swap, and 2 GiB alignment buffer
    local remaining_mib=$(( disk_mib - EFI_SIZE - SWAP_SIZE - 2048 ))

    # Default rpool size from RPOOL_PERCENT
    local default_rpool_mib=$(( remaining_mib * RPOOL_PERCENT / 100 ))

    echo ""
    echo "======================================================================"
    echo "Disk space breakdown for $disk:"
    printf "  Total disk:          %dGiB\n" "$(( disk_mib / 1024 ))"
    printf "  EFI partition:     - %dGiB\n" "$(( EFI_SIZE / 1024 ))"
    printf "  Swap partition:    - %dGiB\n" "$(( SWAP_SIZE / 1024 ))"
    printf "  Alignment buffer:  - 2GiB\n"
    printf "  Available for rpool: %dGiB\n" "$(( remaining_mib / 1024 ))"
    echo "======================================================================"
    printf "Default rpool size: %d%% = %dGiB\n" "$RPOOL_PERCENT" "$(( default_rpool_mib / 1024 ))"
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

        local rpool_mib=$(( remaining_mib * pct / 100 ))

        # Soft warning if result is less than 10 GiB
        if [[ $rpool_mib -lt 10240 ]]; then
            echo "Warning: ${pct}% of available space is only $(( rpool_mib / 1024 ))GiB."
            echo "This may be too small for a functional system (recommended: at least 10GiB)."
            local yn
            read -rp "Continue anyway? [y/N]: " yn
            if [[ ! "$yn" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi

        RPOOL_SIZE=$rpool_mib
        echo "rpool size set to: $(( RPOOL_SIZE / 1024 ))GiB"
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
    local disk_mib=$(( disk_bytes / 1024 / 1024 ))

    local datapool_mib=$(( disk_mib - EFI_SIZE - SWAP_SIZE - RPOOL_SIZE - 2048 ))
    # Clamp to 0 if negative (shouldn't happen, but be safe)
    if [[ $datapool_mib -lt 0 ]]; then datapool_mib=0; fi

    local datapool_label="${DATAPOOL_NAME:-<none>}"

    echo ""
    echo "======================================================================"
    echo "INSTALLATION SUMMARY"
    echo "======================================================================"
    echo ""
    printf "Target disk:  %s  (%dGiB total)\n" "$disk" "$(( disk_mib / 1024 ))"
    echo ""
    echo "Partition layout:"
    printf "  Partition 1 (EFI):      %dGiB\n"     "$(( EFI_SIZE / 1024 ))"
    printf "  Partition 2 (Swap):     %dGiB\n"     "$(( SWAP_SIZE / 1024 ))"
    printf "  Partition 3 (rpool):    %dGiB\n"     "$(( RPOOL_SIZE / 1024 ))"
    printf "  Partition 4 (datapool): ~%dGiB (remaining)\n" "$(( datapool_mib / 1024 ))"
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
# MIRROR SPEED SELECTION
################################################################################
# Fetches the GeoIP-filtered mirror list from mirrors.ubuntu.com (HTTP only —
# HTTPS port 443 is unreachable on that host), then measures actual throughput
# by downloading the first 100KB of ls-lR.gz from each candidate (technique
# from Baeldung "Selecting the Fastest Mirror via Command Line in Ubuntu").
# Falls back to a hardcoded list if the dynamic fetch returns fewer than 2
# usable mirrors. Uses awk for float comparison (no bc dependency).
select_fastest_mirror() {
    # ls-lR.gz lives at the mirror root; -r 0-102400 caps download at ~100KB
    # so each test completes in ≤2s regardless of file size
    local test_file="ls-lR.gz"
    local curl_timeout=2
    local fallback="https://archive.ubuntu.com/ubuntu"

    # Hardcoded fallback candidates (used when GeoIP list is unavailable)
    local -a builtin_candidates=(
        "https://archive.ubuntu.com/ubuntu"
        "https://mirror.init7.net/ubuntu"
        "https://ubuntu.mirror.liteserver.nl/ubuntu"
        "https://ftp.halifax.rwth-aachen.de/ubuntu"
        "https://mirror.de.leaseweb.net/ubuntu"
        "https://mirrors.edge.kernel.org/ubuntu"
    )

    echo ""
    echo "Fetching regional Ubuntu mirror list..."

    local -a candidates=()

    local raw_list
    # Use HTTP (not HTTPS) — mirrors.ubuntu.com port 443 times out;
    # port 80 returns the GeoIP-filtered list correctly
    if raw_list=$(curl -s --max-time 10 "http://mirrors.ubuntu.com/mirrors.txt" 2>/dev/null) \
        && [[ -n "$raw_list" ]]; then
        mapfile -t candidates < <(
            printf '%s\n' "$raw_list" \
            | awk '/^https?:\/\// { gsub(/\/$/, ""); print $1 }' \
            | awk '!seen[$0]++' \
            | head -n 8
        )
        echo "  Retrieved ${#candidates[@]} regional mirrors"
    else
        echo "  Could not fetch mirror list, using built-in candidates."
    fi

    # Fall back to hardcoded list when GeoIP returned nothing useful
    if (( ${#candidates[@]} < 2 )); then
        candidates=("${builtin_candidates[@]}")
        echo "  Using built-in candidate list."
    fi

    echo "  Testing ${#candidates[@]} mirrors (100KB sample each)..."

    local best_mirror=""
    local best_speed="0"

    for mirror in "${candidates[@]}"; do
        local speed
        speed=$(curl -s --max-time "$curl_timeout" -r 0-102400 -o /dev/null \
            -w "%{speed_download}" \
            "${mirror}/${test_file}" 2>/dev/null) || speed="0"
        [[ -z "$speed" ]] && speed="0"

        local speed_kb
        speed_kb=$(awk -v s="$speed" 'BEGIN { printf "%.0f", s/1024 }')
        printf "  %-55s %s KB/s\n" "$mirror" "$speed_kb"

        if awk -v s="$speed" -v b="$best_speed" 'BEGIN { exit !(s > b) }'; then
            best_speed="$speed"
            best_mirror="$mirror"
        fi
    done

    if [[ -n "$best_mirror" ]] && awk -v b="$best_speed" 'BEGIN { exit !(b > 0) }'; then
        APT_MIRROR="$best_mirror"
        local best_kb
        best_kb=$(awk -v s="$best_speed" 'BEGIN { printf "%.0f", s/1024 }')
        echo "  ✓ Selected mirror: $APT_MIRROR (${best_kb} KB/s)"
    else
        APT_MIRROR="$fallback"
        echo "  ✓ All mirror tests failed, using fallback: $APT_MIRROR"
    fi
}

################################################################################
# INSTALLATION MODE
################################################################################
MODE="${1:-}"

if [[ -z "$MODE" ]]; then
    echo "Usage: $0 {initial|postreboot|reinstall-zbm}"
    echo ""
    echo "  initial       - Run from live USB to install system"
    echo "  postreboot    - Run after first boot to complete setup"
    echo "  reinstall-zbm - Reinstall or update ZFSBootMenu to latest version"
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

    # ── PRE-FLIGHT CHECKS (abort before any user interaction) ──────────────────

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

    # Verify network connectivity before any user interaction
    echo ""
    echo "Checking network connectivity..."
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 9.9.9.9 >/dev/null 2>&1; then
        # ICMP may be blocked; try curl then wget as HTTPS fallback
        if ! curl -s --max-time 10 -o /dev/null https://archive.ubuntu.com 2>/dev/null \
            && ! wget -q --spider --timeout=10 https://archive.ubuntu.com 2>/dev/null; then
            echo "Error: No network connectivity detected (tested ICMP and HTTPS)!"
            echo "This script requires internet access for:"
            echo "  - Package downloads (apt, debootstrap)"
            echo "  - ZFSBootMenu git repository"
            echo "  - Zellij binary download"
            echo "Please check your network connection and try again."
            exit 1
        fi
        echo "  ✓ Network connectivity verified (HTTPS - ICMP blocked)"
    else
        echo "  ✓ Network connectivity verified"
    fi

    # Prefer IPv4 for apt to avoid slow/unreachable IPv6 Ubuntu mirrors
    sed -i 's,#precedence ::ffff:0:0/96  100,precedence ::ffff:0:0/96  100,' /etc/gai.conf
    echo "  ✓ IPv4 preferred for apt (IPv6 workaround applied)"

    # ── INTERACTIVE CONFIGURATION ──────────────────────────────────────────────

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

    # Show full confirmation table and require explicit YES before any destructive steps
    show_disk_confirmation "$DISK"

    # ── INSTALLATION (all user input done, nothing below is interactive) ────────

    # Start logging all output to a persistent install log
    INSTALL_LOG="/var/log/zbm-install.log"
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    echo "Installation log: $INSTALL_LOG"

    echo "======================================================================"
    echo "Starting Ubuntu 24.04 ZFSBootMenu Installation"
    echo "======================================================================"

    echo ""
    echo "Step 1: Installing prerequisites..."
    apt update
    # curl needed for select_fastest_mirror and chroot downloads
    apt install -y curl debootstrap gdisk zfs-initramfs

    # Select fastest apt mirror now that curl is guaranteed to be available
    select_fastest_mirror

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
    echo "Step 2: Partitioning disk $DISK..."

    # Check if any partitions on the disk are mounted
    echo "Checking for mounted partitions on $DISK..."
    if lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | grep -qv '^$'; then
        echo "Error: Disk $DISK has mounted partitions!"
        echo "Mounted partitions:"
        lsblk -no NAME,MOUNTPOINT "$DISK"
        echo ""
        echo "Please unmount all partitions before running this script."
        exit 1
    fi
    echo "No mounted partitions found."

    echo "Checking for existing ZFS labels on $DISK..."
    if zpool import 2>/dev/null | grep -q "$(basename "$DISK")"; then
        echo "Warning: Disk $DISK appears to be part of an importable ZFS pool!"
        echo "Proceeding will destroy that pool's data."
        echo "Press Ctrl+C within 10 seconds to abort, or wait to continue..."
        sleep 10
    fi

    sgdisk --zap-all "$DISK"
    sgdisk -n1:0:+${EFI_SIZE}M -t1:EF00 "$DISK"     # EFI  (MiB)
    sgdisk -n2:0:+${SWAP_SIZE}M -t2:8200 "$DISK"    # Swap (MiB)
    sgdisk -n3:0:+${RPOOL_SIZE}M -t3:BF00 "$DISK"   # rpool (MiB)
    if [[ -n "$DATAPOOL_NAME" ]]; then
        sgdisk -n4:0:0 -t4:BF00 "$DISK"             # datapool (ZFS partition)
    fi

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
    if [[ -n "$DATAPOOL_NAME" ]]; then
        DISK_DATAPOOL="${DISK}${PART_PREFIX}4"
    fi

    # Verify all partitions were created successfully (with retry)
    echo "Verifying partitions were created..."
    MAX_RETRIES=5
    RETRY_DELAY=1
    PARTS_TO_CHECK=("$DISK_EFI" "$DISK_SWAP" "$DISK_RPOOL")
    if [[ -n "$DATAPOOL_NAME" ]]; then
        PARTS_TO_CHECK+=("$DISK_DATAPOOL")
    fi
    for part in "${PARTS_TO_CHECK[@]}"; do
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

    # Wait for udev to finish creating /dev/disk/by-partuuid/ symlinks before resolving
    udevadm settle

    # Resolve stable by-id paths for ZFS pool creation
    echo "Resolving partition by-id paths..."
    DISK_RPOOL_ID=$(resolve_part_byid "$DISK_RPOOL")
    echo "  rpool:    $DISK_RPOOL_ID"
    if [[ -n "$DATAPOOL_NAME" ]]; then
        DISK_DATAPOOL_ID=$(resolve_part_byid "$DISK_DATAPOOL")
        echo "  datapool: $DISK_DATAPOOL_ID"
    fi

    # Stop and mask ALL ZFS live-system services BEFORE touching disks.
    # wipefs/zpool labelclear fire udev events; zed reacts to device changes
    # and can ABRT if it races against pool creation on the same partitions.
    # Also include zfs-mount, zfs-share, zfs-import-bpool which Ubuntu 24.04
    # live ISO may have active in addition to the core import/scan services.
    systemctl stop  zed zfs-zed zfs-import-scan zfs-import-cache zfs-mount zfs-share zfs-import-bpool 2>/dev/null || true
    systemctl mask  zed zfs-zed zfs-import-scan zfs-import-cache zfs-mount zfs-share zfs-import-bpool 2>/dev/null || true
    pkill -x zed 2>/dev/null || true
    sleep 1  # let services fully terminate before udev events from wipefs

    # Limit ZFS ARC on low-RAM systems to prevent OOM during debootstrap.
    # Set before any ZFS operations so the cap is in effect from the start.
    # ZFS ARC defaults to ~50% of RAM; on 2-4GB VMs this leaves too little for debootstrap.
    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [[ $total_ram_kb -le 4194304 ]]; then
        echo 536870912 > /sys/module/zfs/parameters/zfs_arc_max
        echo "  ZFS ARC capped at 512MB (<=4GB RAM detected)"
    fi

    # Wipe any existing filesystem signatures and ZFS labels
    echo "Clearing filesystem signatures..."
    wipefs -a "$DISK_EFI" 2>/dev/null || true
    wipefs -a "$DISK_SWAP" 2>/dev/null || true
    wipefs -a "$DISK_RPOOL" 2>/dev/null || true
    if [[ -n "$DATAPOOL_NAME" ]]; then
        wipefs -a "$DISK_DATAPOOL" 2>/dev/null || true
    fi

    # Clear any ZFS labels specifically
    zpool labelclear -f "$DISK_RPOOL" 2>/dev/null || true
    if [[ -n "$DATAPOOL_NAME" ]]; then
        zpool labelclear -f "$DISK_DATAPOOL" 2>/dev/null || true
    fi

    echo ""
    echo "Step 3: Creating ZFS root pool..."
    # Create rpool with monolithic structure
    zpool create -f \
        -o ashift=$ASHIFT \
        -o autotrim=on \
        -O acltype=posixacl \
        -O atime=$ZFS_ATIME \
        -O canmount=off \
        -O compression=${COMPRESSION} \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=$ZFS_RELATIME \
        -O xattr=sa \
        -O mountpoint=none \
        rpool "$DISK_RPOOL_ID"

    # Create single monolithic root dataset
    zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT
    zfs create -o mountpoint=/ rpool/ROOT/ubuntu-1

    # Mount root
    zpool export rpool
    zpool import -N -R /mnt rpool
    zfs mount rpool/ROOT/ubuntu-1


    echo ""
    echo "Step 4: Formatting EFI partition..."
    mkfs.vfat -F32 "$DISK_EFI"
    mkdir -p /mnt/boot/efi
    mount "$DISK_EFI" /mnt/boot/efi

    echo ""
    echo "Step 5: Setting up swap..."
    # Swap will be encrypted at boot via crypttab (ephemeral random key per boot)
    # No mkswap needed — cryptsetup will format the swap device on each boot

    # Capture EFI UUID for stable fstab entry (robust against disk renaming)
    DISK_EFI_UUID=$(blkid -s UUID -o value "$DISK_EFI")

    echo ""
    echo "Step 6: Installing Ubuntu base system..."
    debootstrap noble /mnt "$APT_MIRROR"

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
    echo "Step 7: Configuring base system..."

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

    # Configure apt sources (using selected mirror; security always via official archive)
    cat > /mnt/etc/apt/sources.list << EOF
deb $APT_MIRROR noble main restricted universe multiverse
deb $APT_MIRROR noble-updates main restricted universe multiverse
deb https://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
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
    echo "Step 8: Installing packages in chroot..."

    # Write APT snapshot cleanup script and systemd units to new system before chroot
    # (written here with quoted heredocs to avoid $ escaping inside the chroot heredoc)
    mkdir -p /mnt/usr/local/bin /mnt/etc/systemd/system
    cat > /mnt/usr/local/bin/cleanup-apt-snapshots.sh << 'EOF'
#!/bin/bash
# Cleanup old APT ZFS snapshots — keeps at most KEEP_COUNT newest

set -euo pipefail

DATASET="rpool/ROOT/ubuntu-1"
SNAPSHOT_PREFIX="apt-"
KEEP_COUNT=10

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
    chmod +x /mnt/usr/local/bin/cleanup-apt-snapshots.sh

    cat > /mnt/etc/systemd/system/cleanup-apt-snapshots.service << 'EOF'
[Unit]
Description=Cleanup old APT ZFS snapshots
Documentation=man:zfs(8)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cleanup-apt-snapshots.sh
StandardOutput=journal
StandardError=journal
EOF

    cat > /mnt/etc/systemd/system/cleanup-apt-snapshots.timer << 'EOF'
[Unit]
Description=Twice-daily cleanup of old APT ZFS snapshots
Documentation=man:zfs(8)

[Timer]
OnCalendar=*-*-* 00,12:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Create chroot script with proper variable expansion
    # NOTE: Using unquoted EOF allows variable expansion for $LOCALE, $INSTALL_DOCKER,
    # $INSTALL_ZELLIJ, $USERNAME. Use \$ for variables that must be evaluated inside chroot.
    cat > /mnt/tmp/chroot-install.sh << EOF
#!/bin/bash
set -euo pipefail

# Set locale
locale-gen "$LOCALE"
update-locale LANG="$LOCALE"

# Configure keyboard layout
cat > /etc/default/keyboard << KBEOF
XKBLAYOUT="$KEYBOARD_LAYOUT"
XKBVARIANT="$KEYBOARD_VARIANT"
XKBOPTIONS=""
BACKSPACE="guess"
KBEOF
dpkg-reconfigure -f noninteractive keyboard-configuration
# Apply console keyboard layout (may not succeed in chroot, non-fatal)
setupcon --force 2>/dev/null || true

# Make transient apt errors fatal so stale package lists don't cause silent failures
echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/30apt_error_on_transient

# Bootstrap: install ca-certificates and curl first so HTTPS mirrors work
# and curl is available for Docker/Zellij installs later in this script
apt install -y --no-install-recommends ca-certificates curl

# Update package lists and upgrade base system using the selected mirror
apt update
apt dist-upgrade -y

# Install remaining packages
apt install -y --no-install-recommends \
    locales \
    linux-generic \
    zfs-initramfs \
    zfsutils-linux \
    zfs-zed \
    cryptsetup \
    openssh-server \
    wget \
    vim \
    htop \
    net-tools \
    iproute2 \
    keyboard-configuration \
    console-setup \
    ubuntu-server \
    pv \
    mbuffer \
    ncdu \
    dkms \
    software-properties-common \
    sanoid

# Configure ZFS in initramfs
echo "zfs" >> /etc/initramfs-tools/modules

# Update initramfs (must run after ZFS packages)
update-initramfs -c -k all

# Enable network services
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Mount /tmp as tmpfs
echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,size=2G 0 0" >> /etc/fstab

# Generate netplan backend config files
netplan generate

# Point /etc/resolv.conf at systemd-resolved stub resolver
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Configure Sanoid for rpool
mkdir -p /etc/sanoid
cat > /etc/sanoid/sanoid.conf << 'SANEOF'
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
SANEOF

# APT hook: ZFS snapshot before package upgrades
cat > /etc/apt/apt.conf.d/80-zfs-snapshot << 'HOOKEOF'
// Take ZFS snapshot before package upgrades
DPkg::Pre-Invoke {"if command -v zfs >/dev/null 2>&1; then zfs snapshot rpool/ROOT/ubuntu-1@apt-\$(date +%Y-%m-%d-%H%M%S) || true; fi";};
HOOKEOF

# Enable Sanoid, cleanup timer, and other services
systemctl enable sanoid.timer
systemctl enable cleanup-apt-snapshots.timer
systemctl enable systemd-timesyncd
systemctl enable zfs-zed

# Mask TPM2 setup services — not used by ZFSBootMenu; avoids boot FAILED noise
systemctl mask systemd-tpm2-setup-early.service systemd-tpm2-setup.service

# Take initial snapshot
sanoid --take-snapshots --verbose

# Docker install
if [[ "$INSTALL_DOCKER" == "y" ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    CODENAME=\$(. /etc/os-release && echo "\${UBUNTU_CODENAME:-\$VERSION_CODENAME}")
    ARCH=\$(dpkg --print-architecture)
    cat > /etc/apt/sources.list.d/docker.sources << DOCKEREOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: \${CODENAME}
Components: stable
Architectures: \${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
DOCKEREOF
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo "Docker \$(docker --version) installed"
fi

# Zellij install
if [[ "$INSTALL_ZELLIJ" == "y" ]]; then
    ZELLIJ_VERSION=\$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest | grep -Po '"tag_name": "v\K[^"]*')
    if [[ -z "\$ZELLIJ_VERSION" ]] || [[ ! "\$ZELLIJ_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Warning: Could not fetch Zellij version, using fallback 0.43.1"
        ZELLIJ_VERSION="0.43.1"
    fi
    ZELLIJ_ARCH=\$(uname -m)
    case "\$ZELLIJ_ARCH" in
        x86_64)  ZELLIJ_ARCH_SUFFIX="x86_64-unknown-linux-musl" ;;
        aarch64) ZELLIJ_ARCH_SUFFIX="aarch64-unknown-linux-musl" ;;
        *)
            echo "Unsupported architecture '\$ZELLIJ_ARCH', skipping Zellij"
            ZELLIJ_ARCH_SUFFIX="" ;;
    esac
    if [[ -n "\$ZELLIJ_ARCH_SUFFIX" ]]; then
        if curl -L "https://github.com/zellij-org/zellij/releases/download/v\${ZELLIJ_VERSION}/zellij-\${ZELLIJ_ARCH_SUFFIX}.tar.gz" -o /tmp/zellij.tar.gz; then
            tar -xzf /tmp/zellij.tar.gz -C /tmp
            mv /tmp/zellij /usr/local/bin/
            chmod +x /usr/local/bin/zellij
            rm /tmp/zellij.tar.gz
            echo "Zellij \$(zellij --version) installed"
        else
            echo "Warning: Failed to download Zellij, skipping"
        fi
    fi
fi

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
    echo "Step 9: Creating user and setting passwords..."

    # Create user setup script with proper variable expansion
    # NOTE: Using unquoted EOF allows variable expansion (e.g., $USERNAME, $TIMEZONE)
    cat > /mnt/tmp/user-setup.sh << EOF
#!/bin/bash
set -euo pipefail

# Create user with sudo access and standard Ubuntu groups
useradd -m -s /bin/bash -G sudo,adm,cdrom,dip,plugdev "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "User '$USERNAME' created with sudo access."
# Add to docker group if docker was installed
getent group docker &>/dev/null && usermod -aG docker "$USERNAME" || true

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

    # Tabby SFTP integration: notify terminal of current directory on each prompt
    # Written directly (not via chroot heredoc) to avoid quoting/expansion issues
    cat >> "/mnt/home/$USERNAME/.bash_profile" << 'PROFILE_EOF'
export PS1="$PS1\[\e]1337;CurrentDir="'$(pwd)\a\]'
PROFILE_EOF
    # Resolve UID/GID from installed system (user doesn't exist on live host)
    TARGET_UID=$(grep "^$USERNAME:" /mnt/etc/passwd | cut -d: -f3)
    TARGET_GID=$(grep "^$USERNAME:" /mnt/etc/passwd | cut -d: -f4)
    chown "$TARGET_UID:$TARGET_GID" "/mnt/home/$USERNAME/.bash_profile"
    echo "  ✓ User setup completed"

    echo ""
    echo "Step 10: Installing ZFSBootMenu..."

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

# Fetch latest ZFSBootMenu release version dynamically
ZBM_VERSION=\$(curl -s https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest \
    | grep -Po '"tag_name": "\Kv[^"]*' || true)
if [[ -z "\$ZBM_VERSION" ]] || [[ ! "\$ZBM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "  Warning: Could not fetch latest ZBM version, falling back to v2.3.0"
    ZBM_VERSION="v2.3.0"
fi
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
    ZBM_BOOT_NUM=\$(efibootmgr | grep "ZFSBootMenu" | grep -i "vmlinuz" | head -1 | sed 's/Boot\([0-9A-F]*\).*/\1/')
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
    echo "Step 11: Configuring SSH..."
    chroot /mnt systemctl enable ssh

    echo ""
    echo "Step 12: Setting ZFS properties for boot..."
    zpool set bootfs=rpool/ROOT/ubuntu-1 rpool

    echo ""
    echo "Step 13: Verifying installation..."

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
    echo "Step 14: Copying installation script for post-reboot..."
    INSTALL_DIR="/mnt/home/$USERNAME/zbm-installer"
    mkdir -p "$INSTALL_DIR"
    cp "$0" "$INSTALL_DIR/"
    chmod 700 "$INSTALL_DIR/$(basename "$0")"

    # Persist installation config so postreboot phase can source it
    cat > "$INSTALL_DIR/zbm-installer.conf" <<EOF
USERNAME="$USERNAME"
DISK="$DISK"
PART_PREFIX="$PART_PREFIX"
DISK_RPOOL_ID="$DISK_RPOOL_ID"
DISK_DATAPOOL_ID="$DISK_DATAPOOL_ID"
DATAPOOL_NAME="$DATAPOOL_NAME"
DATAPOOL_MOUNTPOINT="$DATAPOOL_MOUNTPOINT"
KEYBOARD_LAYOUT="$KEYBOARD_LAYOUT"
KEYBOARD_VARIANT="$KEYBOARD_VARIANT"
INSTALL_ZELLIJ="$INSTALL_ZELLIJ"
INSTALL_DOCKER="$INSTALL_DOCKER"
EOF
    chmod 600 "$INSTALL_DIR/zbm-installer.conf"
    TARGET_UID=$(awk -F: -v user="$USERNAME" '$1==user {print $3}' /mnt/etc/passwd)
    TARGET_GID=$(awk -F: -v user="$USERNAME" '$1==user {print $4}' /mnt/etc/passwd)
    chown -R "$TARGET_UID:$TARGET_GID" "$INSTALL_DIR"
    echo "  ✓ Installation script and config saved to ~/zbm-installer/"

    # Copy install log into new system so it survives after reboot
    mkdir -p /mnt/var/log 2>/dev/null || true
    cp "$INSTALL_LOG" /mnt/var/log/zbm-install.log 2>/dev/null || true

    echo ""
    echo "Step 15: Unmounting and exporting pool..."

    # Kill any processes still using /mnt to prevent busy-mount failures
    fuser -km /mnt 2>/dev/null || true

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

    # Explicitly release ZFS datasets before exporting, then sync to flush I/O
    zfs unmount -a 2>/dev/null || true
    sync

    if ! zpool export rpool 2>/dev/null; then
        echo "  Note: Normal export failed, retrying with force flag..."
        if ! zpool export -f rpool 2>/dev/null; then
            echo "  Warning: Pool export failed — pool will be recovered on next import."
        fi
    fi

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
    echo "  4. Run: sudo ~/zbm-installer/$(basename "$0") postreboot"
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

    # Load persisted installation config from initial phase (co-located with this script)
    INSTALL_CONF="$(dirname "$0")/zbm-installer.conf"
    if [[ -f "$INSTALL_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$INSTALL_CONF"
        echo "  ✓ Loaded installation config from $INSTALL_CONF"
    else
        echo "Warning: $INSTALL_CONF not found."
        echo "Datapool creation will use DISK/DATAPOOL_NAME from script defaults."
    fi

    validate_inputs
    echo "Configuration validated successfully."

    echo ""
    echo "Step 0: Checking network connectivity..."
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 9.9.9.9 >/dev/null 2>&1; then
        # ICMP may be blocked; try HTTPS as fallback
        if ! curl -s --max-time 10 -o /dev/null https://archive.ubuntu.com; then
            echo "Error: No network connectivity detected (tested ICMP and HTTPS)!"
            echo "Please check your network connection and try again."
            exit 1
        fi
        echo "  ✓ Network connectivity verified (HTTPS - ICMP blocked)"
    else
        echo "  ✓ Network connectivity verified"
    fi

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
    echo "Step 1: Starting snapshot timers..."
    systemctl enable --now sanoid.timer
    systemctl enable --now cleanup-apt-snapshots.timer
    echo "  ✓ Sanoid and cleanup timers active"

    # Optional: Create datapool if configured
    if [[ -n "$DATAPOOL_NAME" ]]; then
        echo ""
        echo "Step 2: Creating datapool '$DATAPOOL_NAME'..."

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

        # Use persisted by-id/by-partuuid path; re-resolve if missing or a raw device path
        if [[ -z "${DISK_DATAPOOL_ID:-}" ]] || [[ "$DISK_DATAPOOL_ID" != /dev/disk/* ]]; then
            DISK_DATAPOOL_ID=$(resolve_part_byid "$DATAPOOL_PARTITION")
        fi
        echo "  - Using partition: $DISK_DATAPOOL_ID"

        # Create mount point
        echo "  - Creating mount point: $DATAPOOL_MOUNTPOINT"
        mkdir -p "$DATAPOOL_MOUNTPOINT"

        # Create the pool (idempotent: skip if already imported)
        echo "  - Creating ZFS pool: $DATAPOOL_NAME"
        if zpool list "$DATAPOOL_NAME" &>/dev/null; then
            echo "  ✓ Datapool '$DATAPOOL_NAME' already imported, skipping creation"
        else
            zpool create -o ashift=$ASHIFT \
                         -O compression=${COMPRESSION} \
                         -O atime=$ZFS_ATIME \
                         -O mountpoint="$DATAPOOL_MOUNTPOINT" \
                         "$DATAPOOL_NAME" "$DISK_DATAPOOL_ID"
            echo "  ✓ Datapool '$DATAPOOL_NAME' created and mounted at $DATAPOOL_MOUNTPOINT"
        fi

        # Add to Sanoid config (idempotent: skip if section already present)
        echo ""
        if ! grep -q "^\[$DATAPOOL_NAME\]" /etc/sanoid/sanoid.conf; then
            echo "  - Adding datapool to Sanoid configuration..."
            cat >> /etc/sanoid/sanoid.conf << EOF

[$DATAPOOL_NAME]
    use_template = template_production
    recursive = yes
EOF
            echo "  ✓ Sanoid configured for $DATAPOOL_NAME"
        else
            echo "  ✓ Sanoid already configured for $DATAPOOL_NAME, skipping"
        fi

        # Create Docker datasets and configure daemon.json (idempotent)
        if [[ "$INSTALL_DOCKER" == "y" ]]; then
            echo ""
            if ! zpool list "$DATAPOOL_NAME" &>/dev/null; then
                echo "  ⚠ Datapool '$DATAPOOL_NAME' not available — skipping Docker dataset/config setup"
            else
                echo "  - Creating Docker datasets under $DATAPOOL_NAME/docker..."

                # Parent dataset — inherits pool compression/atime
                zfs list "$DATAPOOL_NAME/docker" &>/dev/null || \
                    zfs create "$DATAPOOL_NAME/docker"

                # dockerroot: Docker's data-root (overlay2 layers, images, containers)
                #   recordsize=16K   — overlay2 writes in small blocks
                #   xattr=sa         — required for overlay2
                #   acltype=posixacl — required for overlay2
                zfs list "$DATAPOOL_NAME/docker/dockerroot" &>/dev/null || \
                    zfs create \
                        -o recordsize=16K \
                        -o xattr=sa \
                        -o acltype=posixacl \
                        "$DATAPOOL_NAME/docker/dockerroot"

                # storage: external volume data mounted into containers
                #   default recordsize (128K) suits mixed file sizes
                zfs list "$DATAPOOL_NAME/docker/storage" &>/dev/null || \
                    zfs create "$DATAPOOL_NAME/docker/storage"

                # stack: docker-compose files (small text files)
                #   recordsize=4K — minimises wasted space for tiny config files
                zfs list "$DATAPOOL_NAME/docker/stack" &>/dev/null || \
                    zfs create \
                        -o recordsize=4K \
                        "$DATAPOOL_NAME/docker/stack"

                echo "  ✓ Docker datasets created"

                # Point Docker data-root at the ZFS dataset (idempotent)
                DOCKER_ROOT="$DATAPOOL_MOUNTPOINT/docker/dockerroot"
                DAEMON_JSON="/etc/docker/daemon.json"
                if [[ ! -f "$DAEMON_JSON" ]] || ! grep -q "data-root" "$DAEMON_JSON"; then
                    echo "  - Configuring Docker data-root → $DOCKER_ROOT"
                    mkdir -p /etc/docker
                    cat > "$DAEMON_JSON" << DOCKEREOF
{
    "data-root": "$DOCKER_ROOT",
    "storage-driver": "overlay2"
}
DOCKEREOF
                    systemctl restart docker
                    echo "  ✓ Docker data-root set to $DOCKER_ROOT"
                else
                    echo "  ✓ Docker daemon.json already configured, skipping"
                fi
            fi
        fi
    else
        echo ""
        echo "Step 2: Skipping datapool creation (DATAPOOL_NAME not set)"
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
        if [[ "$INSTALL_DOCKER" == "y" ]]; then
            echo "  2. Docker datasets created automatically:"
            echo "       $DATAPOOL_NAME/docker/dockerroot  ← Docker data-root (images, containers)"
            echo "       $DATAPOOL_NAME/docker/storage     ← External container data"
            echo "       $DATAPOOL_NAME/docker/stack       ← Docker Compose project files"
        else
            echo "  2. Create datasets in $DATAPOOL_NAME as needed (e.g. zfs create $DATAPOOL_NAME/data)"
        fi
    else
        echo "  2. Create your datapool manually when ready:"
        echo "     First, identify your datapool partition with: ls /dev/disk/by-id/ | grep part4"
        echo "     Then: zpool create -o ashift=12 -O compression=lz4 datapool /dev/disk/by-id/PARTITION-ID"
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

################################################################################
# REINSTALL / UPDATE ZFSBOOTMENU (Run on installed system)
################################################################################
elif [[ "$MODE" == "reinstall-zbm" ]]; then
    echo "======================================================================"
    echo "Reinstalling / updating ZFSBootMenu"
    echo "======================================================================"

    # Verify we're running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root"
        exit 1
    fi

    # Verify EFI partition is mounted (sanity check: we're on the installed system)
    if ! mountpoint -q /boot/efi 2>/dev/null; then
        echo "Error: /boot/efi is not mounted."
        echo "Mount it first: mount \$(findmnt -n -o SOURCE /boot/efi) /boot/efi"
        exit 1
    fi

    echo ""
    echo "Step 1: Checking network connectivity..."
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 9.9.9.9 >/dev/null 2>&1; then
        if ! curl -s --max-time 10 -o /dev/null https://api.github.com; then
            echo "Error: No network connectivity detected."
            exit 1
        fi
        echo "  ✓ Network connectivity verified (HTTPS - ICMP blocked)"
    else
        echo "  ✓ Network connectivity verified"
    fi

    echo ""
    echo "Step 2: Fetching latest ZFSBootMenu release..."
    ZBM_VERSION=$(curl -s https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest \
        | grep -Po '"tag_name": "\Kv[^"]*' || true)
    if [[ -z "$ZBM_VERSION" ]] || [[ ! "$ZBM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "  Warning: Could not fetch latest ZBM version, falling back to v2.3.0"
        ZBM_VERSION="v2.3.0"
    fi
    echo "  - Target version: $ZBM_VERSION"

    echo ""
    echo "Step 3: Installing ZFSBootMenu build dependencies..."
    apt update
    apt install -y --no-install-recommends \
        bsdextrautils \
        mbuffer \
        libsort-versions-perl \
        libboolean-perl \
        libyaml-pp-perl \
        git \
        fzf \
        make \
        kexec-tools \
        dracut-core \
        cpio \
        curl \
        systemd-boot \
        binutils \
        efibootmgr

    echo ""
    echo "Step 4: Cloning ZFSBootMenu $ZBM_VERSION..."
    ZBM_SRC="/usr/local/src/zfsbootmenu"
    # Back up existing source if present
    if [[ -d "$ZBM_SRC" ]]; then
        mv "$ZBM_SRC" "${ZBM_SRC}.bak.$(date +%Y%m%d-%H%M%S)"
        echo "  - Backed up existing source dir"
    fi
    mkdir -p "$ZBM_SRC"
    git clone --depth 1 --branch "$ZBM_VERSION" https://github.com/zbm-dev/zfsbootmenu "$ZBM_SRC"
    cd "$ZBM_SRC"

    echo ""
    echo "Step 5: Compiling and installing ZFSBootMenu..."
    make core dracut
    make install

    echo ""
    echo "Step 6: Regenerating ZFSBootMenu image..."
    generate-zbm --debug

    # Verify image was created
    if [[ ! -f /boot/efi/EFI/ZBM/vmlinuz.EFI ]]; then
        echo "Error: ZFSBootMenu image not found after generation!"
        exit 1
    fi

    # Update UEFI fallback path
    mkdir -p /boot/efi/EFI/BOOT
    cp /boot/efi/EFI/ZBM/vmlinuz.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI
    echo "  ✓ Fallback EFI path updated: /EFI/BOOT/BOOTX64.EFI"

    echo ""
    echo "======================================================================"
    echo "ZFSBootMenu $ZBM_VERSION installed successfully!"
    echo "======================================================================"
    echo ""
    echo "Run 'update-zbm' at any time to regenerate the boot image."
    echo ""

else
    echo "Invalid mode: $MODE"
    echo "Usage: $0 {initial|postreboot|reinstall-zbm}"
    exit 1
fi
